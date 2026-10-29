// Orca-owned OS credential bridge. No credentials in argv, environment or files.
// Protocol is bounded line-based stdin/stdout; the key is an opaque SHA-256 scope.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#include <wincred.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#ifdef __APPLE__
#include <Security/Security.h>
#elif defined(__linux__)
#include <libsecret/secret.h>
static const SecretSchema schema = {
    "dev.aiorca.EditorSession", SECRET_SCHEMA_NONE,
    {{"scope", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}},
    0, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr
};
#endif

#ifdef __APPLE__
static CFMutableDictionaryRef keychain_query(const std::string &key) {
    auto query = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    auto account = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8 *>(key.data()), key.size(), kCFStringEncodingUTF8, false);
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, CFSTR("Orca"));
    CFDictionarySetValue(query, kSecAttrAccount, account);
    CFRelease(account);
    return query;
}
#endif

static bool read_line(std::string &line) {
    line.clear();
    char c;
    while (std::cin.get(c)) {
        if (c == '\n') return true;
        if (c < 32 || line.size() >= 16384) return false;
        line += c;
    }
    return false;
}

static std::string get(const std::string &key) {
#ifdef _WIN32
    PCREDENTIALA credential = nullptr;
    if (!CredReadA(("Orca/" + key).c_str(), CRED_TYPE_GENERIC, 0, &credential))
        return GetLastError() == ERROR_NOT_FOUND ? "MISSING" : "ERROR";
    std::string value(reinterpret_cast<char *>(credential->CredentialBlob), credential->CredentialBlobSize);
    CredFree(credential);
#elif defined(__APPLE__)
    auto query = keychain_query(key);
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
    CFTypeRef result = nullptr;
    OSStatus status = SecItemCopyMatching(query, &result);
    CFRelease(query);
    if (status != errSecSuccess) return status == errSecItemNotFound ? "MISSING" : "ERROR";
    if (!result || CFGetTypeID(result) != CFDataGetTypeID()) {
        if (result) CFRelease(result);
        return "ERROR";
    }
    auto data = static_cast<CFDataRef>(result);
    if (CFDataGetLength(data) > 16000) { CFRelease(result); return "ERROR"; }
    std::string value(reinterpret_cast<const char *>(CFDataGetBytePtr(data)), CFDataGetLength(data));
    CFRelease(result);
#elif defined(__linux__)
    GError *error = nullptr;
    gchar *data = secret_password_lookup_sync(&schema, nullptr, &error, "scope", key.c_str(), nullptr);
    if (error) { g_error_free(error); return "ERROR"; }
    if (!data) return "MISSING";
    std::string value(data);
    secret_password_free(data);
#else
    return "ERROR";
#endif
    if (value.size() > 16000 || value.find_first_of("\r\n") != std::string::npos) return "ERROR";
    return "VALUE " + value;
}

static bool put(const std::string &key, const std::string &value) {
#ifdef _WIN32
    std::string target = "Orca/" + key;
    CREDENTIALA credential = {};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = target.data();
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char *>(value.data()));
    credential.CredentialBlobSize = static_cast<DWORD>(value.size());
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteA(&credential, 0);
#elif defined(__APPLE__)
    auto query = keychain_query(key);
    auto data = CFDataCreate(nullptr, reinterpret_cast<const UInt8 *>(value.data()), value.size());
    const void *keys[] = {kSecValueData};
    const void *values[] = {data};
    auto attributes = CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus status = SecItemUpdate(query, attributes);
    if (status == errSecItemNotFound) {
        CFDictionarySetValue(query, kSecValueData, data);
        status = SecItemAdd(query, nullptr);
    }
    CFRelease(attributes);
    CFRelease(data);
    CFRelease(query);
    return status == errSecSuccess;
#elif defined(__linux__)
    GError *error = nullptr;
    bool ok = secret_password_store_sync(&schema, SECRET_COLLECTION_DEFAULT, "Orca editor connection", value.c_str(), nullptr, &error, "scope", key.c_str(), nullptr);
    if (error) g_error_free(error);
    return ok;
#else
    return false;
#endif
}

static bool remove(const std::string &key) {
#ifdef _WIN32
    return CredDeleteA(("Orca/" + key).c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND;
#elif defined(__APPLE__)
    auto query = keychain_query(key);
    OSStatus status = SecItemDelete(query);
    CFRelease(query);
    return status == errSecSuccess || status == errSecItemNotFound;
#elif defined(__linux__)
    GError *error = nullptr;
    secret_password_clear_sync(&schema, nullptr, &error, "scope", key.c_str(), nullptr);
    bool ok = !error; if (error) g_error_free(error); return ok;
#else
    return false;
#endif
}

int main(int argc, char **argv) {
#ifdef _WIN32
    // Godot's private pipe protocol is LF-only; CRT text mode would emit CRLF.
    if (_setmode(_fileno(stdin), _O_BINARY) == -1 || _setmode(_fileno(stdout), _O_BINARY) == -1) return 1;
#endif
    if (argc != 2) return 1;
    std::string key(argv[1]);
    if (key.size() != 64 || key.find_first_not_of("0123456789abcdef") != std::string::npos) return 1;
    // Also bound an unlock/IPC wait if the editor crashes before it can reap us.
    std::thread([] {
        std::this_thread::sleep_for(std::chrono::seconds(180));
        std::_Exit(3);
    }).detach();
    // Held across read -> server refresh -> credential replacement. Multiple
    // editors must reread the latest credential while holding this same lock.
#ifdef _WIN32
    HANDLE lock = CreateMutexA(nullptr, FALSE, ("Local\\OrcaCredential-" + key).c_str());
    if (!lock) return 2;
    DWORD waiting = WaitForSingleObject(lock, 45000);
    if (waiting != WAIT_OBJECT_0 && waiting != WAIT_ABANDONED) return 2;
#else
    std::string path = "/tmp/orca-vault-" + std::to_string(getuid()) + "-" + key + ".lock";
    int lock = open(path.c_str(), O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    struct stat info;
    if (lock < 0 || fstat(lock, &info) || info.st_uid != getuid() || !S_ISREG(info.st_mode) || (info.st_mode & 077)) return 2;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
    while (flock(lock, LOCK_EX | LOCK_NB)) {
        if (std::chrono::steady_clock::now() >= deadline) return 2;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
#endif
    std::cout << "READY\n" << std::flush;
    std::string command;
    while (read_line(command)) {
        if (command == "release") break;
        if (command == "get") std::cout << get(key) << '\n';
        else if (command == "delete") std::cout << (remove(key) ? "OK" : "ERROR") << '\n';
        else if (command.rfind("put ", 0) == 0 && command.size() > 4) std::cout << (put(key, command.substr(4)) ? "OK" : "ERROR") << '\n';
        else std::cout << "ERROR\n";
        std::cout << std::flush;
    }
#ifdef _WIN32
    ReleaseMutex(lock); CloseHandle(lock);
#else
    close(lock);
#endif
    return 0;
}
