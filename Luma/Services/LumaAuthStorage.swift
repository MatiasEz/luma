import Foundation
import Supabase

enum LumaAuthStorage {
    static var current: any AuthLocalStorage {
        #if DEBUG
        LumaDebugAuthStorage()
        #else
        KeychainLocalStorage(service: "com.luma.organizer.supabase.auth")
        #endif
    }
}

#if DEBUG
private struct LumaDebugAuthStorage: AuthLocalStorage {
    private let valuePrefix = "luma.debug.supabase.session."
    private let migrationPrefix = "luma.debug.supabase.migration."

    func store(key: String, value: Data) throws {
        UserDefaults.standard.set(value, forKey: valuePrefix + key)
    }

    func retrieve(key: String) throws -> Data? {
        let defaults = UserDefaults.standard
        let valueKey = valuePrefix + key
        if let stored = defaults.data(forKey: valueKey) {
            return stored
        }

        let migrationKey = migrationPrefix + key
        guard !defaults.bool(forKey: migrationKey) else { return nil }
        defaults.set(true, forKey: migrationKey)

        // This preserves the existing anonymous cloud identity. At most, macOS may
        // request access one final time while the old session is copied.
        if let legacyValue = try? KeychainLocalStorage().retrieve(key: key) {
            defaults.set(legacyValue, forKey: valueKey)
            return legacyValue
        }
        return nil
    }

    func remove(key: String) throws {
        UserDefaults.standard.removeObject(forKey: valuePrefix + key)
    }
}
#endif
