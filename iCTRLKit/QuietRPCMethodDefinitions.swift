import Foundation

enum QuietRPCMethodDefinitions {
    static let readOnlyNames: Set<String> = [
        "runtime_status", "device_info", "is_locked", "logs", "recent_logs", "config",
        "screenshot", "page_source", "view_tree", "ui_tree", "find_element", "find_elements",
        "resolve_app", "search_app", "search_apps", "list_apps", "installed_apps",
        "snapshot_api", "stream_ticket", "file_list", "file_read", "file_status"
    ]
    static func requiresUIGate(_ name: String) -> Bool {
        !readOnlyNames.contains(name) && !name.hasPrefix("automation_") && !name.hasPrefix("file_")
    }
    static let methods: [RPCMethodDef] = [
        RPCMethodDef(name: "automation_config", description: "Read quiet readiness; an authenticated device-local token may set enabled after the human installs and validates the two Shortcuts and dedicated Focus. Off by default. Token mode mapping persists across Runner restarts; leases never revive.", params: [RPCParamDef(name: "enabled", type: "boolean", required: false, description: "Explicit opt-in/out; local authenticated request only")], returns: "{enabled,storage_state,scope}"),
        RPCMethodDef(name: "automation_register", description: "Persistently register this authenticated token as automation or manual. An automation token always requires a verified lease for UI, even while quiet is disabled; revoke pairing to retire it. Manual never starts Focus. Not based on client_name or loopback.", params: [RPCParamDef(name: "mode", type: "string", required: true, description: "automation or manual")], returns: "{mode,quiet_available}"),
        RPCMethodDef(name: "automation_begin", description: "Create one exclusive, process-local quiet lease and launch the Begin Shortcut. State remains preparing until a matching single-use loopback callback reports the dedicated Focus. Never retry a lost Begin response; use automation_owner_status.", params: [RPCParamDef(name: "ttl_seconds", type: "integer", required: true, description: "1..300; absolute Focus Until deadline")], returns: "{lease_id,state:'preparing',deadline}"),
        RPCMethodDef(name: "automation_status", description: "Read one owner-bound lease; no UI or Focus action.", params: [RPCParamDef(name: "lease_id", type: "string", required: true, description: "Random lease id from begin")], returns: "{mode,lease_id,state,deadline}"),
        RPCMethodDef(name: "automation_owner_status", description: "Read authenticated token's active lease after an unknown Begin outcome; never replay Begin.", params: [], returns: "{mode,lease_id?,state?,deadline?}"),
        RPCMethodDef(name: "automation_end", description: "Revoke UI immediately and conditionally inspect/end the dedicated Focus; idempotent and no UI replay.", params: [RPCParamDef(name: "lease_id", type: "string", required: true, description: "Owner-bound lease id")], returns: "{mode,lease_id,state,deadline}"),
        RPCMethodDef(name: "automation_takeover", description: "Explicit manual request while automation owns UI. Revokes Agent permission and starts conditional End. Manual UI remains blocked until state is manual_ready; uncertain restoration stays blocked.", params: [RPCParamDef(name: "mode", type: "string", required: true, description: "manual; token must have registered manual mode")], returns: "{state}"),
    ]
}
