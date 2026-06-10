#pragma once
// Cia402.h — minimal CiA-402 state machine helpers (DS402).
// Controlword 0x6040 / Statusword 0x6041, CSP mode 8.
#include <cstdint>

namespace cia402 {

// statusword state decode (masked per DS402 table)
enum class State {
    NotReady, SwitchOnDisabled, ReadyToSwitchOn, SwitchedOn,
    OperationEnabled, QuickStopActive, FaultReactionActive, Fault, Unknown
};

inline State state(uint16_t sw) {
    if ((sw & 0x004F) == 0x0000) return State::NotReady;
    if ((sw & 0x004F) == 0x0040) return State::SwitchOnDisabled;
    if ((sw & 0x006F) == 0x0021) return State::ReadyToSwitchOn;
    if ((sw & 0x006F) == 0x0023) return State::SwitchedOn;
    if ((sw & 0x006F) == 0x0027) return State::OperationEnabled;
    if ((sw & 0x006F) == 0x0007) return State::QuickStopActive;
    if ((sw & 0x004F) == 0x000F) return State::FaultReactionActive;
    if ((sw & 0x004F) == 0x0008) return State::Fault;
    return State::Unknown;
}

// Next controlword to walk toward Operation Enabled (call every cycle).
// 'wantEnable' false walks back to Switched On.
inline uint16_t step(uint16_t sw, bool wantEnable, bool faultReset) {
    const State st = state(sw);
    if (faultReset && st == State::Fault) return 0x0080;       // fault reset edge
    switch (st) {
        case State::Fault:            return 0x0000;
        case State::NotReady:
        case State::SwitchOnDisabled: return 0x0006;           // shutdown
        case State::ReadyToSwitchOn:  return 0x0007;           // switch on
        case State::SwitchedOn:       return wantEnable ? 0x000F : 0x0007;
        case State::OperationEnabled: return wantEnable ? 0x000F : 0x0007;
        case State::QuickStopActive:  return 0x000F;
        default:                      return 0x0006;
    }
}

inline const char *name(State s) {
    switch (s) {
        case State::NotReady:            return "not-ready";
        case State::SwitchOnDisabled:    return "switch-on-disabled";
        case State::ReadyToSwitchOn:     return "ready";
        case State::SwitchedOn:          return "switched-on";
        case State::OperationEnabled:    return "op-enabled";
        case State::QuickStopActive:     return "quick-stop";
        case State::FaultReactionActive: return "fault-reaction";
        case State::Fault:               return "fault";
        default:                         return "unknown";
    }
}

} // namespace cia402
