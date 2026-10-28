import Foundation

enum FileTransferRPCMethods {
    static let names: Set<String> = ["file_begin", "file_write", "file_commit", "file_list", "file_claim", "file_status", "file_read", "file_saved", "file_delete"]
    private static func param(_ name: String, _ type: String, _ description: String) -> RPCParamDef {
        RPCParamDef(name: name, type: type, required: true, description: description)
    }
    private static let id = param("id", "string", "Opaque transfer ID; never a filesystem path")
    static let methods: [RPCMethodDef] = [
        RPCMethodDef(name: "file_begin", description: "Begin explicit transfer, max 256 MiB. Explicit direction pc_to_phone or phone_to_pc; all calls require encrypted paired authorization. Data stays private until recipient saves it. No arbitrary sandbox browsing.", params: [param("direction", "string", "pc_to_phone or phone_to_pc"), param("name", "string", "Display filename only"), param("size", "integer", "Exact bytes")], returns: "{id,chunk_size,max_file_size}"),
        RPCMethodDef(name: "file_write", description: "Append exactly at returned offset. Max 192 KiB decoded. Do not automatically retry ambiguous writes; inspect file_status first.", params: [id, param("offset", "integer", "Exact next byte offset"), param("data", "string", "Base64 bounded chunk")], returns: "{offset}"),
        RPCMethodDef(name: "file_commit", description: "Verify exact size and SHA256; state ready means queued, not saved in Files. Foreground companion to complete incoming save.", params: [id, param("sha256", "string", "64 hex SHA256")], returns: "{id,name,size,state,saved,sha256,direction}"),
        RPCMethodDef(name: "file_list", description: "List ready explicit incoming transfers by default; optional include_progress includes uploading and retained saved/failed queue metadata with can_receive, never sandbox directories, claims or owner credentials.", params: [param("direction", "string", "pc_to_phone or phone_to_pc"), RPCParamDef(name: "include_progress", type: "boolean", required: false, description: "Default false preserves ready-only list; true reports explicit queue progress")], returns: "{files:[{id,name,size,received,state,sha256,direction,can_receive?,saved_name?}]}"),
        RPCMethodDef(name: "file_status", description: "Read transfer progress, saved acknowledgement and saved filename. Ready is pending; only saved:true confirms companion acknowledgement.", params: [id], returns: "{id,name,size,received,state,saved,sha256,saved_name?}"),
        RPCMethodDef(name: "file_claim", description: "Claim incoming transfer with a five-minute receiving lease bound to this paired session. Read renews lease. No client process identity is inferred.", params: [id], returns: "{id,name,size,sha256,lease,lease_expires_in}"),
        RPCMethodDef(name: "file_read", description: "Read bounded chunk of an explicit ready incoming transfer. Encrypted RPC only.", params: [id, param("lease", "string", "Receiving lease from file_claim"), param("offset", "integer", "Byte offset"), param("length", "integer", "1..196608")], returns: "{data,offset,eof}"),
        RPCMethodDef(name: "file_saved", description: "Lease holder reports verified save, exact size and checksum; removes only Runner spool bytes. This is a paired client report, not authenticated process or hardware proof.", params: [id, param("lease", "string", "Receiving lease"), param("name", "string", "Actual non-overwriting saved filename"), param("size", "integer", "Verified byte count"), param("sha256", "string", "Verified SHA256"), param("recipient", "string", "companion or computer; client purpose hint only")], returns: "{state,saved,saved_name}"),
        RPCMethodDef(name: "file_delete", description: "Delete an explicit transfer or abort partial upload. Does not remove an already saved Companion document.", params: [id], returns: "{deleted:true}"),
    ]
}
