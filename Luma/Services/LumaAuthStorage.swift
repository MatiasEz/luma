import Foundation
import Supabase

enum LumaAuthStorage {
    static var current: any AuthLocalStorage {
        LumaPreferencesAuthStorage()
    }
}

/// The distributed app is currently signed ad hoc. macOS ties legacy Keychain
/// permissions to that exact signature, so every new build would ask the user
/// for their login Keychain password again. Keep the anonymous Supabase session
/// in Luma's own preferences until releases use a stable Developer ID signature.
private struct LumaPreferencesAuthStorage: AuthLocalStorage {
    private let valuePrefix = "luma.supabase.session."
    private let legacyDebugPrefix = "luma.debug.supabase.session."

    func store(key: String, value: Data) throws {
        UserDefaults.standard.set(value, forKey: valuePrefix + key)
    }

    func retrieve(key: String) throws -> Data? {
        let defaults = UserDefaults.standard
        let valueKey = valuePrefix + key
        if let stored = defaults.data(forKey: valueKey) {
            return stored
        }

        // Preserve sessions created by development builds without touching the
        // legacy Keychain item, since reading it is what triggers the password UI.
        let legacyKey = legacyDebugPrefix + key
        if let legacyValue = defaults.data(forKey: legacyKey) {
            defaults.set(legacyValue, forKey: valueKey)
            defaults.removeObject(forKey: legacyKey)
            return legacyValue
        }
        return nil
    }

    func remove(key: String) throws {
        UserDefaults.standard.removeObject(forKey: valuePrefix + key)
        UserDefaults.standard.removeObject(forKey: legacyDebugPrefix + key)
    }
}
