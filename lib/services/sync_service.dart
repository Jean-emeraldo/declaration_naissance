import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:io';

import '../models/naissance.dart';
import '../db/database_helper.dart';
import 'dart:developer' as developer;

class SyncService {
  static bool _autoSyncInitialized = false;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  void initializeAutoSync() {
    if (_autoSyncInitialized) return;
    _autoSyncInitialized = true;
    Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((result) => result != ConnectivityResult.none)) {
        unawaited(_syncIfVerified());
      }
    });
    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) unawaited(_syncIfVerified());
    });
    unawaited(_syncIfVerified());
  }

  Future<void> _syncIfVerified() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await user.reload();
      if (FirebaseAuth.instance.currentUser?.emailVerified != true) return;
      await syncAllUnsynced();
    } catch (error, stackTrace) {
      developer.log(
        'Synchronisation automatique indisponible',
        name: 'SyncService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> syncDeclarations(List<Naissance> declarations) async {
    final db = await DatabaseHelper.instance.database;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !user.emailVerified) return;
    for (Naissance declaration in declarations) {
      try {
        final localRows = await db.query(
          'declarations',
          columns: ['syncId'],
          where: 'id = ?',
          whereArgs: [declaration.id],
        );
        if (localRows.isEmpty) continue;
        final syncId = localRows.first['syncId'] as String?;
        if (syncId == null || syncId.isEmpty) continue;
        Map<String, dynamic> data = declaration.toMap();
        data.remove('id');
        data['uid'] = user.uid;
        await _firestore
            .collection('declarations')
            .doc('${user.uid}_$syncId')
            .set(data, SetOptions(merge: true));
        await db.update(
          'declarations',
          {'synced': 1},
          where: 'id = ?',
          whereArgs: [declaration.id],
        );
      } catch (e) {
        developer.log(
          "Erreur lors de la synchronisation de la déclaration id=${declaration.id} : $e",
          name: 'SyncService',
        );
      }
    }
  }

  Future<void> syncUsers(List<Map<String, dynamic>> users) async {
    for (final user in users) {
      if (user['synced'] == 1 || user['firebaseUid'] == null) continue;
      try {
        await syncUser(user);
      } catch (error, stackTrace) {
        developer.log(
          "Erreur lors de la synchronisation d'un utilisateur",
          name: 'SyncService',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<void> syncUser(Map<String, dynamic> user) async {
    if (user['emailVerified'] == 0) return;
    final uid = user['firebaseUid'] as String?;
    if (uid == null || uid.isEmpty) {
      throw StateError(
        'Le compte local n’est pas associé à un compte Firebase.',
      );
    }

    final profile = <String, dynamic>{
      'uid': uid,
      'email': user['email'],
      'firstName': user['firstName'],
      'lastName': user['lastName'],
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final picturePath = user['profilePicture'] as String?;
    if (picturePath != null && picturePath.isNotEmpty) {
      final pictureFile = File(picturePath);
      if (await pictureFile.exists()) {
        final pictureRef = FirebaseStorage.instance.ref(
          'user_profiles/$uid/profile.jpg',
        );
        await pictureRef.putFile(pictureFile);
        profile['profilePicture'] = await pictureRef.getDownloadURL();
      } else if (Uri.tryParse(picturePath)?.hasScheme == true) {
        profile['profilePicture'] = picturePath;
      }
    }

    await _firestore
        .collection('users')
        .doc(uid)
        .set(profile, SetOptions(merge: true));

    final db = await DatabaseHelper.instance.database;
    await db.update(
      'users',
      {'synced': 1},
      where: 'firebaseUid = ?',
      whereArgs: [uid],
    );
  }

  Future<void> syncAllUnsynced() async {
    final db = await DatabaseHelper.instance.database;
    final unsyncedRows = await db.query(
      'declarations',
      where: 'synced = ?',
      whereArgs: [0],
    );
    List<Naissance> unsyncedDeclarations =
        unsyncedRows.map((row) => Naissance.fromMap(row)).toList();
    if (unsyncedDeclarations.isNotEmpty) {
      await syncDeclarations(unsyncedDeclarations);
    }

    int dbVersion = 1;
    try {
      final versionResult = await db.rawQuery('PRAGMA user_version');
      if (versionResult.isNotEmpty && versionResult.first.values.first is int) {
        dbVersion = versionResult.first.values.first as int;
      }
    } catch (_) {}

    if (dbVersion >= 2) {
      final unsyncedUsers = await db.query('users');
      if (unsyncedUsers.isNotEmpty) {
        await syncUsers(unsyncedUsers);
      }
    }
  }

  Future<List<String>> getExistingTables() async {
    final Database db = await DatabaseHelper.instance.database;
    final List<Map<String, dynamic>> tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    return tables.map((t) => t['name'] as String).toList();
  }
}
