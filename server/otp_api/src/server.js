import {
  createHmac,
  randomBytes,
  randomInt,
  timingSafeEqual,
} from 'node:crypto';
import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import pkg from 'pg';
import nodemailer from 'nodemailer';
import { z } from 'zod';
import { applicationDefault, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';

dotenv.config();
const { Pool } = pkg;

const app = express();
app.use(cors());
app.use(express.json({ limit: '16kb' }));
app.use(express.urlencoded({ extended: false, limit: '4kb' }));

const approvalSecret = process.env.APPROVAL_TOKEN_SECRET;
const publicBaseUrl = process.env.PUBLIC_BASE_URL?.replace(/\/+$/, '');
if (!approvalSecret || Buffer.byteLength(approvalSecret) < 32) {
  throw new Error('APPROVAL_TOKEN_SECRET must contain at least 32 bytes.');
}
if (!publicBaseUrl || !publicBaseUrl.startsWith('https://')) {
  throw new Error('PUBLIC_BASE_URL must be an HTTPS URL.');
}

const otpSecret = process.env.OTP_SECRET;
const ttlMinutes = Number(process.env.OTP_TTL_MINUTES || 10);
if (!process.env.DATABASE_URL) {
  throw new Error('DATABASE_URL must be configured.');
}
if (otpSecret && Buffer.byteLength(otpSecret) < 32) {
  throw new Error('OTP_SECRET must contain at least 32 bytes when configured.');
}
if (
  otpSecret &&
  (!Number.isInteger(ttlMinutes) || ttlMinutes < 5 || ttlMinutes > 10)
) {
  throw new Error('OTP_TTL_MINUTES must be between 5 and 10.');
}

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
initializeApp({ credential: applicationDefault() });
const firebaseAuth = getAuth();
const requestSchema = z.object({ email: z.string().email().max(254) });
const verifySchema = z.object({
  email: z.string().email().max(254),
  otp: z.string().regex(/^\d{6}$/),
});

const mailer = process.env.SMTP_HOST && process.env.EMAIL_FROM
  ? nodemailer.createTransport({
      host: process.env.SMTP_HOST,
      port: Number(process.env.SMTP_PORT || 587),
      secure: process.env.SMTP_SECURE === 'true',
      auth: process.env.SMTP_USER
        ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS }
        : undefined,
    })
  : null;

const requestTimes = new Map();
const verificationTimes = new Map();
const approvalRequestTimes = new Map();
const approvalTtlMinutes = Number(
  process.env.REGISTRATION_APPROVAL_TTL_MINUTES || 30,
);
if (
  !Number.isInteger(approvalTtlMinutes) ||
  approvalTtlMinutes < 5 ||
  approvalTtlMinutes > 60
) {
  throw new Error('REGISTRATION_APPROVAL_TTL_MINUTES must be between 5 and 60.');
}
const approvalRequestSchema = z.object({ email: z.string().email().max(254) });
const approvalDecisionSchema = z.object({
  token: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  decision: z.enum(['approve', 'reject']),
});

app.post(
  '/registration-approvals/request',
  requireFirebaseUser,
  async (req, res) => {
    const parsed = approvalRequestSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'invalid_request' });
    }

    const email = parsed.data.email.trim().toLowerCase();
    const uid = req.firebaseUser.uid;
    if (
      typeof req.firebaseUser.email !== 'string' ||
      req.firebaseUser.email.toLowerCase() !== email
    ) {
      return res.status(403).json({ error: 'email_mismatch' });
    }
    if (req.firebaseUser.firebase?.sign_in_provider !== 'password') {
      return res.status(403).json({ error: 'email_password_required' });
    }

    let existing;
    try {
      existing = await pool.query(
        `SELECT status, expires_at FROM registration_approvals
         WHERE firebase_uid = $1`,
        [uid],
      );
    } catch (error) {
      console.error('Unable to read the registration approval.');
      return res.status(503).json({ error: 'service_unavailable' });
    }

    const current = existing.rows[0];
    if (
      current?.status === 'pending' &&
      new Date(current.expires_at) <= new Date()
    ) {
      try {
        await pool.query(
          `UPDATE registration_approvals
           SET status = 'expired', approval_token_hash = NULL,
               rejection_token_hash = NULL
           WHERE firebase_uid = $1 AND status = 'pending'`,
          [uid],
        );
      } catch (error) {
        console.error('Unable to expire a registration approval.');
        return res.status(503).json({ error: 'service_unavailable' });
      }
      await deleteFirebaseUser(uid).catch(() => {
        console.error('Unable to delete an expired Firebase account.');
      });
      return res.json({ status: 'expired' });
    }
    if (current?.status === 'approved') {
      return res.json({ status: 'approved' });
    }
    if (current?.status === 'rejected' || current?.status === 'expired') {
      return res.json({ status: current.status });
    }
    if (!current && req.firebaseUser.email_verified) {
      return res.status(409).json({ error: 'account_already_exists' });
    }
    if (!mailer) {
      return res.status(503).json({ error: 'email_unavailable' });
    }

    const clientIp = req.ip || 'unknown';
    if (
      isRateLimited(approvalRequestTimes, uid, 3, 15 * 60_000) ||
      isRateLimited(approvalRequestTimes, clientIp, 20, 60 * 60_000)
    ) {
      return res.status(429).json({ error: 'rate_limited' });
    }

    const approvalToken = randomBytes(32).toString('base64url');
    const rejectionToken = randomBytes(32).toString('base64url');
    const expiresAt = new Date(Date.now() + approvalTtlMinutes * 60_000);
    try {
      const saved = await pool.query(
        `INSERT INTO registration_approvals
           (firebase_uid, email, approval_token_hash, rejection_token_hash,
            expires_at, status, created_at)
         VALUES ($1, $2, $3, $4, $5, 'pending', NOW())
         ON CONFLICT (firebase_uid) DO UPDATE
         SET email = EXCLUDED.email,
             approval_token_hash = EXCLUDED.approval_token_hash,
             rejection_token_hash = EXCLUDED.rejection_token_hash,
             expires_at = EXCLUDED.expires_at,
             status = 'pending',
             created_at = NOW()
         WHERE registration_approvals.status = 'pending'
         RETURNING status`,
        [
          uid,
          email,
          hashApprovalToken(approvalToken),
          hashApprovalToken(rejectionToken),
          expiresAt,
        ],
      );
      if (saved.rowCount === 0) {
        const latest = await pool.query(
          `SELECT status FROM registration_approvals WHERE firebase_uid = $1`,
          [uid],
        );
        if (latest.rows[0]?.status === 'approved') {
          return res.json({ status: 'approved' });
        }
        if (
          latest.rows[0]?.status === 'rejected' ||
          latest.rows[0]?.status === 'expired'
        ) {
          return res.json({ status: latest.rows[0].status });
        }
        return res.status(503).json({ error: 'service_unavailable' });
      }

      const approveUrl =
        `${publicBaseUrl}/registration-approvals/action?token=`
        + encodeURIComponent(approvalToken);
      const rejectUrl =
        `${publicBaseUrl}/registration-approvals/action?token=`
        + encodeURIComponent(rejectionToken);
      await mailer.sendMail({
        from: process.env.EMAIL_FROM,
        to: email,
        subject: 'Confirmez cette demande de création de compte',
        text:
          'Une tentative de création de compte vient d’être effectuée avec votre adresse email. '
          + 'Confirmez si c’est vous. Si vous ne l’avez pas initiée, refusez-la : le compte sera annulé.\n\n'
          + `Confirmer : ${approveUrl}\n`
          + `Refuser : ${rejectUrl}\n\n`
          + `Ces liens expirent dans ${approvalTtlMinutes} minutes.`,
        html:
          `<p>Une tentative de création de compte vient d’être effectuée avec votre adresse email. `
          + `Confirmez si c’est vous. Si vous ne l’avez pas initiée, refusez-la : le compte sera annulé.</p>`
          + `<p><a href="${approveUrl}">Confirmer la demande</a></p>`
          + `<p><a href="${rejectUrl}">Refuser la demande</a></p>`
          + `<p>Ces liens expirent dans ${approvalTtlMinutes} minutes.</p>`,
      });
      return res.json({
        status: 'pending',
        expiresAt: expiresAt.toISOString(),
      });
    } catch (error) {
      await pool
        .query(
          `UPDATE registration_approvals
           SET status = 'expired', approval_token_hash = NULL,
               rejection_token_hash = NULL
           WHERE firebase_uid = $1 AND status = 'pending'`,
          [uid],
        )
        .catch(() => {
          console.error('Unable to cancel a registration approval request.');
        });
      await deleteFirebaseUser(uid).catch(() => {
        console.error('Unable to delete an account after email delivery failed.');
      });
      console.error('Unable to send the account approval email.');
      return res.status(503).json({ error: 'email_unavailable' });
    }
  },
);

app.get(
  '/registration-approvals/status',
  requireFirebaseUser,
  async (req, res) => {
    try {
      const result = await pool.query(
        `SELECT status, expires_at FROM registration_approvals
         WHERE firebase_uid = $1`,
        [req.firebaseUser.uid],
      );
      if (result.rows.length === 0) {
        return res.json({ status: 'not_requested' });
      }

      const approval = result.rows[0];
      if (
        approval.status === 'pending' &&
        new Date(approval.expires_at) <= new Date()
      ) {
        await expireRegistrationApprovals();
        return res.json({ status: 'expired' });
      }
      return res.json({ status: approval.status });
    } catch (error) {
      console.error('Unable to read the registration approval status.');
      return res.status(503).json({ error: 'service_unavailable' });
    }
  },
);

app.get('/registration-approvals/action', (req, res) => {
  const token = z.string().regex(/^[A-Za-z0-9_-]{43}$/).safeParse(
    req.query.token,
  );
  if (!token.success) {
    return res
      .status(400)
      .type('html')
      .send(renderPage('Lien invalide', 'Ce lien de confirmation est invalide.'));
  }
  res.set('Cache-Control', 'no-store');
  res.set('Referrer-Policy', 'no-referrer');
  return res.type('html').send(renderApprovalPage(token.data));
});

app.post('/registration-approvals/decision', async (req, res) => {
  const parsed = approvalDecisionSchema.safeParse(req.body);
  if (!parsed.success) {
    return res
      .status(400)
      .type('html')
      .send(renderPage('Lien invalide', 'Ce lien de confirmation est invalide.'));
  }

  const { token, decision } = parsed.data;
  const tokenHash = hashApprovalToken(token);
  let client;
  let userId;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    const result = await client.query(
      `SELECT firebase_uid, status, expires_at,
              approval_token_hash, rejection_token_hash
       FROM registration_approvals
       WHERE approval_token_hash = $1 OR rejection_token_hash = $1
       LIMIT 1 FOR UPDATE`,
      [tokenHash],
    );
    if (result.rows.length === 0) {
      await client.query('ROLLBACK');
      return res
        .status(404)
        .type('html')
        .send(renderPage('Lien expiré', 'Ce lien est invalide ou a déjà été utilisé.'));
    }

    const approval = result.rows[0];
    userId = approval.firebase_uid;
    const tokenMatchesDecision =
      decision === 'approve'
        ? approval.approval_token_hash === tokenHash
        : approval.rejection_token_hash === tokenHash;
    if (approval.status !== 'pending' || !tokenMatchesDecision) {
      await client.query('ROLLBACK');
      return res
        .status(409)
        .type('html')
        .send(renderPage('Demande déjà traitée', 'Cette demande n’est plus en attente.'));
    }

    if (new Date(approval.expires_at) <= new Date()) {
      await client.query(
        `UPDATE registration_approvals
         SET status = 'expired', approval_token_hash = NULL,
             rejection_token_hash = NULL
         WHERE firebase_uid = $1`,
        [userId],
      );
      await client.query('COMMIT');
      await deleteFirebaseUser(userId).catch(() => {
        console.error('Unable to delete an expired Firebase account.');
      });
      return res
        .type('html')
        .send(renderPage('Demande expirée', 'La demande a expiré. Recommencez l’inscription.'));
    }

    if (decision === 'approve') {
      await firebaseAuth.updateUser(userId, { emailVerified: true });
      await client.query(
        `UPDATE registration_approvals
         SET status = 'approved', approval_token_hash = NULL,
             rejection_token_hash = NULL
         WHERE firebase_uid = $1`,
        [userId],
      );
      await client.query('COMMIT');
      return res
        .type('html')
        .send(renderPage('Compte confirmé', 'Votre demande est confirmée. Revenez dans l’application pour terminer l’inscription.'));
    }

    await client.query(
      `UPDATE registration_approvals
       SET status = 'rejected', approval_token_hash = NULL,
           rejection_token_hash = NULL
       WHERE firebase_uid = $1`,
      [userId],
    );
    await client.query('COMMIT');
    await deleteFirebaseUser(userId).catch(() => {
      console.error('Unable to delete a rejected Firebase account.');
    });
    return res
      .type('html')
      .send(renderPage('Demande refusée', 'La demande a été refusée et le compte a été annulé.'));
  } catch (error) {
    if (client) {
      await client.query('ROLLBACK').catch(() => {
        console.error('Unable to rollback registration approval.');
      });
    }
    console.error('Unable to process the registration approval decision.');
    return res
      .status(503)
      .type('html')
      .send(renderPage('Erreur', 'La demande n’a pas pu être traitée. Réessayez plus tard.'));
  } finally {
    client?.release();
  }
});

function isRateLimited(store, key, limit, windowMs) {
  const now = Date.now();
  const recent = (store.get(key) || []).filter((time) => now - time < windowMs);
  if (recent.length >= limit) {
    store.set(key, recent);
    return true;
  }
  recent.push(now);
  store.set(key, recent);
  return false;
}

function removeExpiredRateLimits(store, windowMs) {
  const now = Date.now();
  for (const [key, timestamps] of store) {
    const recent = timestamps.filter((time) => now - time < windowMs);
    if (recent.length === 0) {
      store.delete(key);
    } else {
      store.set(key, recent);
    }
  }
}

function hashApprovalToken(token) {
  return createHmac('sha256', approvalSecret).update(token).digest('hex');
}

function renderPage(title, message, content = '') {
  return `<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title}</title>
  <style>
    body{font-family:Arial,sans-serif;background:#f3f6f8;color:#24313a;margin:0;padding:24px}
    main{max-width:480px;margin:10vh auto;background:white;border-radius:16px;padding:32px;box-shadow:0 8px 32px #0001}
    h1{font-size:24px}p{line-height:1.55}.actions{display:flex;gap:12px;margin-top:24px}
    button{flex:1;padding:14px;border:0;border-radius:10px;font-size:16px;font-weight:bold;cursor:pointer}
    .approve{background:#1abc9c;color:white}.reject{background:#eee;color:#333}
  </style>
</head>
<body><main><h1>${title}</h1><p>${message}</p>${content}</main></body>
</html>`;
}

function renderApprovalPage(token) {
  const actionForm = (decision, label, style) => `
    <form method="post" action="/registration-approvals/decision">
      <input type="hidden" name="token" value="${token}">
      <input type="hidden" name="decision" value="${decision}">
      <button class="${style}" type="submit">${label}</button>
    </form>`;
  return renderPage(
    'Confirmer la création du compte',
    'Une demande de création de compte a été faite avec votre adresse email. '
      + 'Si vous êtes à l’origine de cette demande, confirmez-la. Sinon, refusez-la.',
    `<div class="actions">${actionForm('approve', 'Confirmer', 'approve')}`
      + `${actionForm('reject', 'Refuser', 'reject')}</div>`,
  );
}

async function requireFirebaseUser(req, res, next) {
  const match = /^Bearer (.+)$/.exec(req.get('authorization') || '');
  if (!match) return res.status(401).json({ error: 'unauthorized' });
  try {
    req.firebaseUser = await firebaseAuth.verifyIdToken(match[1]);
    return next();
  } catch (error) {
    return res.status(401).json({ error: 'unauthorized' });
  }
}

async function deleteFirebaseUser(uid) {
  try {
    await firebaseAuth.deleteUser(uid);
  } catch (error) {
    if (error.code !== 'auth/user-not-found') throw error;
  }
}

async function expireRegistrationApprovals() {
  const expired = await pool.query(
    `UPDATE registration_approvals
     SET status = 'expired', approval_token_hash = NULL,
         rejection_token_hash = NULL
     WHERE status = 'pending' AND expires_at <= NOW()
     RETURNING firebase_uid`,
  );
  const rejected = await pool.query(
    `SELECT firebase_uid FROM registration_approvals
     WHERE status IN ('rejected', 'expired') LIMIT 100`,
  );
  for (const { firebase_uid: uid } of [
    ...expired.rows,
    ...rejected.rows,
  ]) {
    try {
      await deleteFirebaseUser(uid);
    } catch (error) {
      console.error('Unable to delete a cancelled Firebase account.');
    }
  }
}

const rateLimitCleanup = setInterval(() => {
  removeExpiredRateLimits(requestTimes, 60 * 60_000);
  removeExpiredRateLimits(verificationTimes, 60 * 60_000);
  removeExpiredRateLimits(approvalRequestTimes, 60 * 60_000);
}, 60 * 60_000);
rateLimitCleanup.unref();
const approvalCleanup = setInterval(() => {
  expireRegistrationApprovals().catch(() => {
    console.error('Unable to clean up expired registration approvals.');
  });
}, 5 * 60_000);
approvalCleanup.unref();

function hashOtp(email, otp) {
  return createHmac('sha256', otpSecret)
    .update(`${email}:${otp}`)
    .digest('hex');
}

app.post('/otp/request', async (req, res) => {
  const parsed = requestSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: 'invalid_request' });
  if (!mailer || !otpSecret) {
    return res.status(503).json({ error: 'email_unavailable' });
  }

  const email = parsed.data.email.trim().toLowerCase();
  const clientIp = req.ip || 'unknown';
  if (
    isRateLimited(requestTimes, email, 1, 60_000) ||
    isRateLimited(requestTimes, clientIp, 10, 60 * 60_000)
  ) {
    return res.status(429).json({ error: 'rate_limited' });
  }

  const otp = randomInt(100000, 1000000).toString();
  let client;
  let otpId;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    await client.query(
      `DELETE FROM email_otp_codes
       WHERE used = true OR expires_at < NOW() - INTERVAL '1 day'`,
    );
    await client.query(
      'UPDATE email_otp_codes SET used = true WHERE email = $1 AND used = false',
      [email],
    );
    const result = await client.query(
      `INSERT INTO email_otp_codes (email, code_hash, expires_at)
       VALUES ($1, $2, NOW() + ($3 * INTERVAL '1 minute'))
       RETURNING id`,
      [email, hashOtp(email, otp), ttlMinutes],
    );
    otpId = result.rows[0].id;
    await client.query('COMMIT');
  } catch (error) {
    if (client) {
      await client.query('ROLLBACK').catch(() => {
        console.error('Unable to rollback email verification code transaction.');
      });
    }
    console.error('Unable to create email verification code.');
    return res.status(503).json({ error: 'service_unavailable' });
  } finally {
    client?.release();
  }

  try {
    await mailer.sendMail({
      from: process.env.EMAIL_FROM,
      to: email,
      subject: 'Votre code de vérification',
      text: `Votre code de vérification est ${otp}. Il expire dans ${ttlMinutes} minutes.`,
    });
    return res.json({ ok: true });
  } catch (error) {
    await pool
      .query('UPDATE email_otp_codes SET used = true WHERE id = $1', [otpId])
      .catch((updateError) => {
        console.error('Unable to invalidate undelivered email verification code.');
      });
    console.error('Unable to deliver email verification code.');
    return res.status(503).json({ error: 'email_unavailable' });
  }
});

app.post('/otp/verify', async (req, res) => {
  const parsed = verifySchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: 'invalid_request' });
  if (!otpSecret) return res.status(503).json({ error: 'service_unavailable' });

  const email = parsed.data.email.trim().toLowerCase();
  const clientIp = req.ip || 'unknown';
  if (isRateLimited(verificationTimes, clientIp, 30, 60 * 60_000)) {
    return res.status(429).json({ error: 'rate_limited' });
  }

  let client;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    const result = await client.query(
      `SELECT id, code_hash, expires_at, attempts
       FROM email_otp_codes
       WHERE email = $1 AND used = false
       ORDER BY id DESC
       LIMIT 1
       FOR UPDATE`,
      [email],
    );
    if (result.rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(400).json({ ok: false, reason: 'invalid' });
    }

    const row = result.rows[0];
    if (new Date(row.expires_at) <= new Date()) {
      await client.query(
        'UPDATE email_otp_codes SET used = true WHERE id = $1',
        [row.id],
      );
      await client.query('COMMIT');
      return res.status(400).json({ ok: false, reason: 'expired' });
    }
    if (row.attempts >= 5) {
      await client.query(
        'UPDATE email_otp_codes SET used = true WHERE id = $1',
        [row.id],
      );
      await client.query('COMMIT');
      return res.status(429).json({ error: 'rate_limited' });
    }

    const expectedHash = Buffer.from(row.code_hash, 'hex');
    const actualHash = Buffer.from(hashOtp(email, parsed.data.otp), 'hex');
    if (
      expectedHash.length !== actualHash.length ||
      !timingSafeEqual(expectedHash, actualHash)
    ) {
      const attempts = row.attempts + 1;
      await client.query(
        'UPDATE email_otp_codes SET attempts = $1, used = $2 WHERE id = $3',
        [attempts, attempts >= 5, row.id],
      );
      await client.query('COMMIT');
      return res.status(400).json({ ok: false, reason: 'invalid' });
    }

    await client.query(
      'UPDATE email_otp_codes SET used = true WHERE id = $1',
      [row.id],
    );
    await client.query('COMMIT');
    return res.json({ ok: true });
  } catch (error) {
    if (client) {
      await client.query('ROLLBACK').catch(() => {
        console.error('Unable to rollback email verification transaction.');
      });
    }
    console.error('Unable to verify email verification code.');
    return res.status(503).json({ error: 'service_unavailable' });
  } finally {
    client?.release();
  }
});

app.get('/health', (_req, res) => res.json({ ok: true }));

const port = Number(process.env.PORT || 4000);
try {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS email_otp_codes (
      id BIGSERIAL PRIMARY KEY,
      email TEXT NOT NULL,
      code_hash CHAR(64) NOT NULL,
      expires_at TIMESTAMPTZ NOT NULL,
      used BOOLEAN NOT NULL DEFAULT false,
      attempts INTEGER NOT NULL DEFAULT 0
    )
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS registration_approvals (
      firebase_uid TEXT PRIMARY KEY,
      email TEXT NOT NULL,
      approval_token_hash CHAR(64),
      rejection_token_hash CHAR(64),
      expires_at TIMESTAMPTZ NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected', 'expired')),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
  await pool.query(
    'CREATE INDEX IF NOT EXISTS email_otp_codes_email_id_idx ON email_otp_codes (email, id DESC)',
  );
  await pool.query(
    'CREATE INDEX IF NOT EXISTS registration_approvals_expiry_idx ON registration_approvals (expires_at) WHERE status = \'pending\'',
  );
  await expireRegistrationApprovals();
  app.listen(port, () =>
    console.log(`Registration approval API listening on :${port}`),
  );
} catch (error) {
  console.error('Unable to initialize the OTP API database.');
  await pool.end();
  process.exitCode = 1;
}
