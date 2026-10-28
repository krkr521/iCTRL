import Foundation

enum DevelopmentRPCMethods {
    static var readOnlyNames: Set<String> {
        #if DEBUG
        return ["shade_system_artifact"]
        #else
        return []
        #endif
    }
    static var methods: [RPCMethodDef] {
        #if DEBUG
        return [RPCMethodDef(
            name: "shade_system_artifact",
            description: "Debug-only, authenticated and read-only: read the fixed Apple AutomationModeUI executable. event_synthesis is disabled and returns unavailable with reason diagnostic_disabled without runtime inspection or file access. Ordinary sandbox file access only; no class loading, memory/shared-cache read, arbitrary paths, app data, writes or permission bypass. Metadata by default; max file2MiB/chunk48KiB. Stop on unavailable/denied/oversize; results do not prove shade behavior.",
            params: [RPCParamDef(name: "artifact", type: "string", required: true, description: "Exactly automation_ui or event_synthesis (disabled); never a path"),
                     RPCParamDef(name: "offset", type: "integer", required: false, description: "0..2097152; default0"),
                     RPCParamDef(name: "length", type: "integer", required: false, description: "0(metadata only)..49152; default0")],
            returns: "{artifact,system_version_description,status,reason?,size?,offset?,length?,data_base64?,eof?}"
        ), RPCMethodDef(
            name: "shade_probe",
            description: "Development-only inspection of the existing XCTest automation session. Explicit attempt_restore=true permits one synchronous restore experiment per Runner lifetime; never retry after a timeout. A successful return does not prove physical display state.",
            params: [RPCParamDef(name: "attempt_restore", type: "boolean", required: false,
                description: "Default false inspects only. True makes at most one private enable call; no timer or automatic policy.")],
            returns: "{class_available,session_available,selector_available,attempted,returned,error_domain,error_code,elapsed_ms}"
        )]
        #else
        return []
        #endif
    }
}
