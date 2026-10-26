import Foundation

enum NativeRPCMethodDefinitions {
    private static let foreground = RPCParamDef(name: "foreground", type: "boolean", required: false, description: "Default true. Temporarily foreground the runner for UIKit clipboard access. Never unlocks the device or grants paste permission.")
    private static let restore = RPCParamDef(name: "restore_app", type: "boolean", required: false, description: "Default true. Restore the original app when safely identifiable; restored_app reports the observed result. Permission prompts may require user action.")
    static let methods: [RPCMethodDef] = [
        RPCMethodDef(name: "clipboard_get", description: "Read native iOS plain-text clipboard. May foreground Runner and show an iOS paste permission prompt. Maximum 65536 UTF-8 bytes, no NUL. Never automatically repeat a timed-out clipboard operation.", params: [foreground, restore], returns: "{native:true, text:string, has_text:boolean, change_count:number, restored_app:boolean}; -32040 errors contain reason, mutation_started, may_have_completed, requires_user_action"),
        RPCMethodDef(name: "clipboard_set", description: "Write native iOS plain text. Maximum 65536 UTF-8 bytes, no NUL; never logged. Do not retry after an ambiguous timeout.", params: [RPCParamDef(name: "text", type: "string", required: true, description: "Plain text, at most 65536 UTF-8 bytes, no NUL"), foreground, restore], returns: "{native:true, written:true, utf8_bytes:number, restored_app:boolean}"),
        RPCMethodDef(name: "clipboard_clear", description: "Clear the native iOS clipboard. Requires unlocked foreground Runner; no lock bypass or automatic paste permission grant.", params: [foreground, restore], returns: "{native:true, cleared:true, restored_app:boolean}"),
        RPCMethodDef(name: "runtime_status", description: "Read current service/DDI/foreground keep-awake state and only this Runner's embedded-profile expiry and non-sensitive bundle/team identifiers. No clipboard access and no certificate, profile or pairing data.", params: [], returns: "{server_running,server_version,ddi_mounted,bundle_id,team_identifier,runner_profile_expires_at,runner_profile_expiry_available,keep_awake_enabled,keep_awake_scope,runner_foreground,idle_timer_assertion_active,cross_app_auto_lock_prevention:false}"),
    ]
}
