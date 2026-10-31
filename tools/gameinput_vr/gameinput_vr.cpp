// gameinput_vr.dll - loaded into Gears of War: E-Day at process start (by the launcher), before the
// engine creates its GameInput object. The game reads gamepads only through GameInput v3 (no XInput), so UEVR's
// "VR controllers as a gamepad" never reached it. This DLL adds a virtual GameInput gamepad:
//   - when the game registers its device callback, it is told a gamepad connected (our VirtualGamepad),
//   - GetCurrentReading for that device returns the state last pushed by UEVR via gameinput_vr_set_gamepad().
#include <windows.h>
#include <share.h>

#include <atomic>
#include <cstdio>
#include <algorithm>
#include <mutex>
#include <vector>

#include "GameInput.h"

using namespace GameInput::v3;

namespace {
std::mutex g_log_mtx;
FILE* g_log = nullptr;

void log(const char* fmt, ...) {
    std::scoped_lock _{g_log_mtx};

    if (g_log == nullptr) {
        return;
    }

    SYSTEMTIME t{};
    GetLocalTime(&t);
    fprintf(g_log, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);

    va_list args;
    va_start(args, fmt);
    vfprintf(g_log, fmt, args);
    va_end(args);

    fputc('\n', g_log);
    fflush(g_log);
}

// Latest state pushed by UEVR.
std::mutex g_state_mtx;
GameInputGamepadState g_state{};
std::atomic<uint64_t> g_state_updates{0};

IGameInput* g_game_input = nullptr; // our own instance, for timestamps

constexpr GameInputKind VIRTUAL_KINDS = GameInputKindGamepad | GameInputKindController;

class VirtualGamepad final : public IGameInputDevice {
public:
    VirtualGamepad() {
        m_gamepad_info.supportedLayout = GameInputGamepadMenu | GameInputGamepadView | GameInputGamepadA | GameInputGamepadB |
            GameInputGamepadX | GameInputGamepadY | GameInputGamepadDPadUp | GameInputGamepadDPadDown | GameInputGamepadDPadLeft |
            GameInputGamepadDPadRight | GameInputGamepadLeftShoulder | GameInputGamepadRightShoulder |
            GameInputGamepadLeftThumbstick | GameInputGamepadRightThumbstick;
        m_gamepad_info.menuButtonLabel = GameInputLabelXboxMenu;
        m_gamepad_info.viewButtonLabel = GameInputLabelXboxView;
        m_gamepad_info.aButtonLabel = GameInputLabelXboxA;
        m_gamepad_info.bButtonLabel = GameInputLabelXboxB;
        m_gamepad_info.xButtonLabel = GameInputLabelXboxX;
        m_gamepad_info.yButtonLabel = GameInputLabelXboxY;

        // Looks like an Xbox Series controller so the game shows Xbox button prompts.
        m_info.vendorId = 0x045E;
        m_info.productId = 0x0B12;
        m_info.usage = {0x01, 0x05};
        m_info.deviceFamily = GameInputFamilyXboxOne;
        m_info.supportedInput = VIRTUAL_KINDS;
        m_info.displayName = "UEVR Virtual Gamepad";
        m_info.pnpPath = "UEVR\\VirtualGamepad";
        m_info.gamepadInfo = &m_gamepad_info;
        memcpy(&m_info.deviceId, "UEVRVirtualGamepad-E-Day-00000000", sizeof(m_info.deviceId));
        m_info.deviceRootId = m_info.deviceId;
    }

    // IUnknown. Lives for the whole process, so reference counting is a no-op.
    IFACEMETHOD(QueryInterface)(REFIID riid, void** out) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IGameInputDevice)) {
            *out = this;
            return S_OK;
        }

        *out = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHOD_(ULONG, AddRef)() override { return 1; }
    IFACEMETHOD_(ULONG, Release)() override { return 1; }

    IFACEMETHOD(GetDeviceInfo)(const GameInputDeviceInfo** info) override {
        *info = &m_info;
        return S_OK;
    }
    IFACEMETHOD(GetHapticInfo)(GameInputHapticInfo*) override { return GAMEINPUT_E_HAPTIC_INFO_NOT_FOUND; }
    IFACEMETHOD_(GameInputDeviceStatus, GetDeviceStatus)() override { return GameInputDeviceConnected; }
    IFACEMETHOD(CreateForceFeedbackEffect)(uint32_t, const GameInputForceFeedbackParams*, IGameInputForceFeedbackEffect** effect) override {
        *effect = nullptr;
        return GAMEINPUT_E_FEEDBACK_NOT_SUPPORTED;
    }
    IFACEMETHOD_(bool, IsForceFeedbackMotorPoweredOn)(uint32_t) override { return false; }
    IFACEMETHOD_(void, SetForceFeedbackMotorGain)(uint32_t, float) override {}
    IFACEMETHOD_(void, SetRumbleState)(const GameInputRumbleParams*) override {} // TODO: forward to VR controller haptics
    IFACEMETHOD(DirectInputEscape)(uint32_t, const void*, uint32_t, void*, uint32_t, uint32_t*) override { return E_NOTIMPL; }
    IFACEMETHOD(CreateInputMapper)(IGameInputMapper** mapper) override {
        *mapper = nullptr;
        return E_NOTIMPL;
    }
    IFACEMETHOD(GetExtraAxisCount)(GameInputKind, uint32_t* count) override {
        *count = 0;
        return S_OK;
    }
    IFACEMETHOD(GetExtraButtonCount)(GameInputKind, uint32_t* count) override {
        *count = 0;
        return S_OK;
    }
    IFACEMETHOD(GetExtraAxisIndexes)(GameInputKind, uint32_t, uint8_t*) override { return S_OK; }
    IFACEMETHOD(GetExtraButtonIndexes)(GameInputKind, uint32_t, uint8_t*) override { return S_OK; }
    IFACEMETHOD(CreateRawDeviceReport)(uint32_t, GameInputRawDeviceReportKind, IGameInputRawDeviceReport** report) override {
        *report = nullptr;
        return E_NOTIMPL;
    }
    IFACEMETHOD(SendRawDeviceOutput)(IGameInputRawDeviceReport*) override { return E_NOTIMPL; }

private:
    GameInputDeviceInfo m_info{};
    GameInputGamepadInfo m_gamepad_info{};
};

VirtualGamepad g_device{};

// One immutable snapshot of the gamepad state; the game releases it when done.
class VirtualReading final : public IGameInputReading {
public:
    VirtualReading(const GameInputGamepadState& state, uint64_t timestamp) : m_state{state}, m_timestamp{timestamp} {}

    IFACEMETHOD(QueryInterface)(REFIID riid, void** out) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IGameInputReading)) {
            AddRef();
            *out = this;
            return S_OK;
        }

        *out = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHOD_(ULONG, AddRef)() override { return ++m_refs; }
    IFACEMETHOD_(ULONG, Release)() override {
        const auto refs = --m_refs;

        if (refs == 0) {
            delete this;
        }

        return refs;
    }

    IFACEMETHOD_(GameInputKind, GetInputKind)() override { return VIRTUAL_KINDS; }
    IFACEMETHOD_(uint64_t, GetTimestamp)() override { return m_timestamp; }
    IFACEMETHOD_(void, GetDevice)(IGameInputDevice** device) override { *device = &g_device; }
    IFACEMETHOD_(uint32_t, GetControllerAxisCount)() override { return 0; }
    IFACEMETHOD_(uint32_t, GetControllerAxisState)(uint32_t, float*) override { return 0; }
    IFACEMETHOD_(uint32_t, GetControllerButtonCount)() override { return 0; }
    IFACEMETHOD_(uint32_t, GetControllerButtonState)(uint32_t, bool*) override { return 0; }
    IFACEMETHOD_(uint32_t, GetControllerSwitchCount)() override { return 0; }
    IFACEMETHOD_(uint32_t, GetControllerSwitchState)(uint32_t, GameInputSwitchPosition*) override { return 0; }
    IFACEMETHOD_(uint32_t, GetKeyCount)() override { return 0; }
    IFACEMETHOD_(uint32_t, GetKeyState)(uint32_t, GameInputKeyState*) override { return 0; }
    IFACEMETHOD_(bool, GetMouseState)(GameInputMouseState*) override { return false; }
    IFACEMETHOD_(bool, GetSensorsState)(GameInputSensorsState*) override { return false; }
    IFACEMETHOD_(bool, GetArcadeStickState)(GameInputArcadeStickState*) override { return false; }
    IFACEMETHOD_(bool, GetFlightStickState)(GameInputFlightStickState*) override { return false; }
    IFACEMETHOD_(bool, GetGamepadState)(GameInputGamepadState* state) override {
        *state = m_state;
        return true;
    }
    IFACEMETHOD_(bool, GetRacingWheelState)(GameInputRacingWheelState*) override { return false; }
    IFACEMETHOD_(bool, GetRawReport)(IGameInputRawDeviceReport** report) override {
        *report = nullptr;
        return false;
    }

private:
    std::atomic<ULONG> m_refs{1};
    GameInputGamepadState m_state;
    uint64_t m_timestamp;
};

// --- IGameInput v3 vtable hooks (shared vtable in GameInputRedist.dll, patched in place) ---
constexpr size_t GET_CURRENT_TIMESTAMP = 3;
constexpr size_t GET_CURRENT_READING = 4;
constexpr size_t GET_NEXT_READING = 5;
constexpr size_t GET_PREVIOUS_READING = 6;
constexpr size_t REGISTER_READING_CALLBACK = 7;
constexpr size_t REGISTER_DEVICE_CALLBACK = 8;
constexpr size_t STOP_CALLBACK = 11;
constexpr size_t UNREGISTER_CALLBACK = 12;
constexpr size_t VTABLE_SIZE = 32;

void* g_original[VTABLE_SIZE]{};

using GetCurrentTimestampFn = uint64_t(STDMETHODCALLTYPE*)(IGameInput*);
using GetCurrentReadingFn = HRESULT(STDMETHODCALLTYPE*)(IGameInput*, GameInputKind, IGameInputDevice*, IGameInputReading**);
using GetRelativeReadingFn = HRESULT(STDMETHODCALLTYPE*)(IGameInput*, IGameInputReading*, GameInputKind, IGameInputDevice*, IGameInputReading**);
using RegisterReadingCallbackFn = HRESULT(STDMETHODCALLTYPE*)(IGameInput*, IGameInputDevice*, GameInputKind, void*, GameInputReadingCallback, GameInputCallbackToken*);
using StopCallbackFn = void(STDMETHODCALLTYPE*)(IGameInput*, GameInputCallbackToken);
using UnregisterCallbackFn = bool(STDMETHODCALLTYPE*)(IGameInput*, GameInputCallbackToken);
using RegisterDeviceCallbackFn = HRESULT(STDMETHODCALLTYPE*)(IGameInput*, IGameInputDevice*, GameInputKind, GameInputDeviceStatus,
    GameInputEnumerationKind, void*, GameInputDeviceCallback, GameInputCallbackToken*);

uint64_t now_timestamp() {
    return g_game_input != nullptr ? ((GetCurrentTimestampFn)g_original[GET_CURRENT_TIMESTAMP])(g_game_input) : 0;
}

// Test aid: while a file named "press_a" sits next to this DLL, the A button reads as held.
wchar_t g_press_a_path[MAX_PATH]{};
std::atomic<bool> g_test_press_a{false};
std::atomic<uint64_t> g_readings{0};
std::atomic<uint64_t> g_next_reading_calls{0};
std::atomic<uint64_t> g_state_changed_at{0}; // timestamp of the last state change pushed by UEVR

DWORD WINAPI watch_test_files(LPVOID) {
    uint64_t last_calls = 0;

    for (int i = 0;; ++i) {
        const bool press_a = GetFileAttributesW(g_press_a_path) != INVALID_FILE_ATTRIBUTES;

        if (press_a != g_test_press_a.exchange(press_a)) {
            g_state_changed_at = now_timestamp();
            log("test file: A %s", press_a ? "held" : "released");
        }

        if (i % 100 == 0 && g_next_reading_calls != last_calls) {
            log("GetNextReading calls/10s: %llu", g_next_reading_calls - last_calls);
            last_calls = g_next_reading_calls;
        }

        Sleep(100);
    }
}

IGameInputReading* make_reading() {
    const auto n = g_readings++;

    if (n == 0 || n == 1000 || n == 100000) {
        log("game read the virtual gamepad (reading %llu)", n);
    }

    // Reading rate once per ~5 s, to see how the game polls.
    static auto last = GetTickCount64();
    static uint64_t last_n = 0;
    static uint64_t last_next = 0;
    if (GetTickCount64() - last > 5000) {
        log("reads/5s: current=%llu next=%llu", n - last_n, g_next_reading_calls.load() - last_next);
        last = GetTickCount64();
        last_n = n;
        last_next = g_next_reading_calls.load();
    }

    std::scoped_lock _{g_state_mtx};
    auto state = g_state;

    if (g_test_press_a) {
        state.buttons |= GameInputGamepadA;
    }

    return new VirtualReading(state, now_timestamp());
}

HRESULT STDMETHODCALLTYPE get_current_reading(IGameInput* self, GameInputKind kind, IGameInputDevice* device, IGameInputReading** reading) {
    const auto wants_gamepad = (kind & GameInputKindGamepad) != 0;

    if (device == &g_device && wants_gamepad) {
        *reading = make_reading();
        return S_OK;
    }

    const auto hr = ((GetCurrentReadingFn)g_original[GET_CURRENT_READING])(self, kind, device, reading);

    // "Any gamepad" query with no real gamepad around: answer with ours.
    if (device == nullptr && wants_gamepad && FAILED(hr)) {
        *reading = make_reading();
        return S_OK;
    }

    return hr;
}

template <size_t IDX>
HRESULT STDMETHODCALLTYPE get_relative_reading(IGameInput* self, IGameInputReading* ref, GameInputKind kind, IGameInputDevice* device, IGameInputReading** reading) {
    // UE polls GetNextReading(last reading) every frame. We keep no history: if the state changed
    // after the game's last reading, the "next" one is the current state, otherwise there is none.
    if (device == &g_device) {
        if (g_next_reading_calls++ == 0) {
            log("game asked for a relative reading (method %zu) of the virtual gamepad", IDX);
        }

        if (IDX == GET_NEXT_READING && ref != nullptr && ref->GetTimestamp() < g_state_changed_at.load()) {
            *reading = make_reading();
            return S_OK;
        }

        *reading = nullptr;
        return GAMEINPUT_E_READING_NOT_FOUND;
    }

    return ((GetRelativeReadingFn)g_original[IDX])(self, ref, kind, device, reading);
}

HRESULT STDMETHODCALLTYPE register_device_callback(IGameInput* self, IGameInputDevice* device, GameInputKind kind, GameInputDeviceStatus status_filter,
    GameInputEnumerationKind enumeration, void* context, GameInputDeviceCallback callback, GameInputCallbackToken* token)
{
    const auto hr = ((RegisterDeviceCallbackFn)g_original[REGISTER_DEVICE_CALLBACK])(self, device, kind, status_filter, enumeration, context, callback, token);
    log("RegisterDeviceCallback(kind=%x, status=%x, enum=%u, callback=%p) -> %08x", kind, status_filter, enumeration, callback, (uint32_t)hr);

    const auto matches = (device == nullptr || device == &g_device) && (kind & VIRTUAL_KINDS) != 0 && (status_filter & GameInputDeviceConnected) != 0;

    if (SUCCEEDED(hr) && matches && callback != nullptr) {
        // Report the virtual gamepad as connected, like enumeration of an already plugged in device.
        callback(token != nullptr ? *token : 0, context, &g_device, now_timestamp(), GameInputDeviceConnected, GameInputDeviceNoStatus);
        log("announced virtual gamepad to callback %p", callback);
    }

    return hr;
}

// The game does not poll a connected gamepad: it registers a reading callback for it and waits to be called.
// GameInput itself never calls back for our virtual device, so we do, whenever UEVR pushes a new state.
struct ReadingCallback {
    GameInputCallbackToken token;
    void* context;
    GameInputReadingCallback callback;
};

std::mutex g_callbacks_mtx;
std::vector<ReadingCallback> g_reading_callbacks;
std::atomic<GameInputCallbackToken> g_next_token{0x5545565200000001ull}; // "UEVR"..., never issued by GameInput

bool is_our_token(GameInputCallbackToken token) {
    std::scoped_lock _{g_callbacks_mtx};
    return std::any_of(g_reading_callbacks.begin(), g_reading_callbacks.end(), [&](const auto& c) { return c.token == token; });
}

void fire_reading_callbacks() {
    std::vector<ReadingCallback> callbacks;
    {
        std::scoped_lock _{g_callbacks_mtx};
        callbacks = g_reading_callbacks;
    }

    for (const auto& c : callbacks) {
        auto reading = make_reading();
        c.callback(c.token, c.context, reading);
        reading->Release(); // the game AddRefs it if it keeps it
    }
}

HRESULT STDMETHODCALLTYPE register_reading_callback(IGameInput* self, IGameInputDevice* device, GameInputKind kind, void* context,
    GameInputReadingCallback callback, GameInputCallbackToken* token)
{
    const auto ours = (device == &g_device || device == nullptr) && (kind & GameInputKindGamepad) != 0 && callback != nullptr;
    log("RegisterReadingCallback(device=%p, kind=%x, callback=%p)%s", device, kind, callback, ours ? " -> virtual gamepad" : "");

    if (!ours) {
        return ((RegisterReadingCallbackFn)g_original[REGISTER_READING_CALLBACK])(self, device, kind, context, callback, token);
    }

    // "Any device" registrations also go to GameInput so real devices keep working.
    if (device == nullptr) {
        ((RegisterReadingCallbackFn)g_original[REGISTER_READING_CALLBACK])(self, device, kind, context, callback, nullptr);
    }

    const auto t = g_next_token++;
    {
        std::scoped_lock _{g_callbacks_mtx};
        g_reading_callbacks.push_back({t, context, callback});
    }

    if (token != nullptr) {
        *token = t;
    }

    return S_OK;
}

void STDMETHODCALLTYPE stop_callback(IGameInput* self, GameInputCallbackToken token) {
    if (!is_our_token(token)) {
        ((StopCallbackFn)g_original[STOP_CALLBACK])(self, token);
    }
}

bool STDMETHODCALLTYPE unregister_callback(IGameInput* self, GameInputCallbackToken token) {
    {
        std::scoped_lock _{g_callbacks_mtx};
        const auto it = std::find_if(g_reading_callbacks.begin(), g_reading_callbacks.end(), [&](const auto& c) { return c.token == token; });

        if (it != g_reading_callbacks.end()) {
            g_reading_callbacks.erase(it);
            log("reading callback %llx unregistered", token);
            return true;
        }
    }

    return ((UnregisterCallbackFn)g_original[UNREGISTER_CALLBACK])(self, token);
}

DWORD WINAPI install(LPVOID) {
    const auto redist = LoadLibraryW(L"GameInputRedist.dll");
    const auto initialize = redist != nullptr ? (decltype(&GameInputInitialize))GetProcAddress(redist, "GameInputInitialize") : nullptr;

    if (initialize == nullptr || FAILED(initialize(__uuidof(IGameInput), (void**)&g_game_input)) || g_game_input == nullptr) {
        log("could not create IGameInput v3 (redist %p)", redist);
        return 1;
    }

    // Every IGameInput v3 instance (ours and the game's) shares this vtable.
    const auto shared = *(void***)g_game_input;
    memcpy(g_original, shared, sizeof(g_original));

    DWORD old{};
    VirtualProtect(shared, sizeof(g_original), PAGE_READWRITE, &old);
    shared[GET_CURRENT_READING] = (void*)&get_current_reading;
    shared[GET_NEXT_READING] = (void*)&get_relative_reading<GET_NEXT_READING>;
    shared[GET_PREVIOUS_READING] = (void*)&get_relative_reading<GET_PREVIOUS_READING>;
    shared[REGISTER_DEVICE_CALLBACK] = (void*)&register_device_callback;
    shared[REGISTER_READING_CALLBACK] = (void*)&register_reading_callback;
    shared[STOP_CALLBACK] = (void*)&stop_callback;
    shared[UNREGISTER_CALLBACK] = (void*)&unregister_callback;
    VirtualProtect(shared, sizeof(g_original), old, &old);

    log("IGameInput v3 vtable %p hooked, virtual gamepad ready", shared);
    return 0;
}
} // namespace

// Called by UEVR every frame with the gamepad state built from the VR controllers.
extern "C" __declspec(dllexport) void gameinput_vr_set_gamepad(uint32_t buttons, float left_trigger, float right_trigger,
    float left_x, float left_y, float right_x, float right_y)
{
    {
        std::scoped_lock _{g_state_mtx};
        g_state.buttons = (GameInputGamepadButtons)buttons;
        g_state.leftTrigger = left_trigger;
        g_state.rightTrigger = right_trigger;
        g_state.leftThumbstickX = left_x;
        g_state.leftThumbstickY = left_y;
        g_state.rightThumbstickX = right_x;
        g_state.rightThumbstickY = right_y;
    }

    if (g_state_updates++ == 0) {
        log("first gamepad state from UEVR received");
    }

    static GameInputGamepadState last_sent{};
    GameInputGamepadState current{};
    {
        std::scoped_lock _{g_state_mtx};
        current = g_state;
    }

    if (memcmp(&current, &last_sent, sizeof(current)) != 0) {
        last_sent = current;
        g_state_changed_at = now_timestamp();
        fire_reading_callbacks();
    }

    // Log changes in buttons / big stick moves so we can see what UEVR sends while the user presses things.
    static uint32_t last_buttons = 0;
    static bool last_trig = false;
    static bool last_stick = false;
    const bool trig = left_trigger > 0.5f || right_trigger > 0.5f;
    const bool stick = fabsf(left_x) > 0.5f || fabsf(left_y) > 0.5f || fabsf(right_x) > 0.5f || fabsf(right_y) > 0.5f;
    if (buttons != last_buttons || trig != last_trig || stick != last_stick) {
        log("UEVR state: buttons=%x LT=%.2f RT=%.2f L=(%.2f,%.2f) R=(%.2f,%.2f)", buttons, left_trigger, right_trigger, left_x, left_y, right_x, right_y);
        last_buttons = buttons;
        last_trig = trig;
        last_stick = stick;
    }
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);

        wchar_t path[MAX_PATH]{};
        GetModuleFileNameW(inst, path, MAX_PATH);
        auto slash = wcsrchr(path, L'\\') + 1;
        wcscpy_s(slash, MAX_PATH - (slash - path), L"gameinput_vr.log");
        g_log = _wfsopen(path, L"w", _SH_DENYNO); // shared, so the log can be read while the game runs
        log("gameinput_vr loaded");

        wcscpy_s(slash, MAX_PATH - (slash - path), L"press_a");
        wcscpy_s(g_press_a_path, path);

        CloseHandle(CreateThread(nullptr, 0, install, nullptr, 0, nullptr));
        CloseHandle(CreateThread(nullptr, 0, watch_test_files, nullptr, 0, nullptr));
    }

    return TRUE;
}
