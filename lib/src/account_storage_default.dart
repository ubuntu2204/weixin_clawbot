// Picks the default [AccountStorage] implementation for the current platform:
// file storage on native (dart:io), localStorage on web, memory otherwise.
export 'account_storage_stub.dart'
    if (dart.library.js_interop) 'account_storage_web.dart'
    if (dart.library.io) 'account_storage_io.dart';
