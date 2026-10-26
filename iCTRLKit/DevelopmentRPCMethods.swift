import Foundation

enum DevelopmentRPCMethods {
    static var methods: [RPCMethodDef] {
        #if DEBUG
        return [RPCMethodDef(
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
