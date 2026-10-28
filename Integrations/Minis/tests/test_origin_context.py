import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"ictrl-ready/scripts"))
import origin_context as o

TASK="a"*32;NONCE="b"*32;SID="11111111-2222-3333-4444-555555555555"

def fixture(command=None):
    command=command or 'python3 -B "$HOME/.ictrl/runtime/task_session.py" prepare && sh "$HOME/.ictrl/runtime/ensure-ictrl.sh"'
    receipt=json.dumps({"kind":"ictrl_origin_prepared","task_id":TASK,"origin_nonce":NONCE})
    listed={"count":1,"sessions":[{"session_id":SID,"message_count":2}]}
    data={"session_id":SID,"tools":True,"total":2,"messages":[
        {"role":"assistant","tool_calls":[{"tool_use_id":"tool_1","name":"shell_execute","input":json.dumps({"command":command})}]},
        {"role":"tool","tool_results":[{"tool_use_id":"tool_1","success":True,"output":receipt+'\n{"ok":true}'}]}]}
    return listed,data

class OriginTests(unittest.TestCase):
    def resolve(self,listed,data):
        calls=[]
        def query(args):calls.append(args);return listed if args[0]=="list" else data
        result=o.resolve_origin(TASK,NONCE,query)
        self.assertEqual(calls[0],["list","--keywords",NONCE,"--limit","2"])
        self.assertEqual(calls[1][0],"messages");self.assertIn("--tools",calls[1]);return result

    def test_completed_previous_prepare_result_binds_exact_origin_without_latest(self):
        listed,data=fixture();result=self.resolve(listed,data);self.assertEqual(result["session_id"],SID);self.assertEqual(result["tool_use_id"],"tool_1")

    def test_explicit_literal_nonce_prepare_is_supported(self):
        listed,data=fixture(f'python3 -B "$HOME/.ictrl/runtime/task_session.py" prepare --task-id {TASK} --origin-nonce {NONCE}')
        self.assertEqual(self.resolve(listed,data)["session_id"],SID)

    def test_current_unpersisted_or_failed_tool_cannot_supply_origin(self):
        for mode in ("missing_result","failed","wrong_nonce","truncated_output"):
            listed,data=fixture();result=data["messages"][1]["tool_results"][0]
            if mode=="missing_result":data["messages"].pop()
            if mode=="failed":result["success"]=False
            if mode=="wrong_nonce":result["output"]=result["output"].replace(NONCE,"c"*32)
            if mode=="truncated_output":result["output_truncated"]=True
            with self.subTest(mode=mode),self.assertRaises(o.OriginContextError):self.resolve(listed,data)

    def test_global_zero_or_multiple_sessions_are_rejected_before_reading_any_chat(self):
        for count in (0,2,100):
            def query(args):
                self.assertEqual(args[0],"list")
                return {"count":count,"sessions":[{"session_id":SID}]*count}
            with self.assertRaises(o.OriginContextError):o.resolve_origin(TASK,NONCE,query)

    def test_title_only_match_echoed_fake_command_and_tool_output_are_not_origin(self):
        for command in ['echo "python3 -B $HOME/.ictrl/runtime/task_session.py prepare"','python3 -c "print(42)"']:
            listed,data=fixture(command)
            with self.assertRaises(o.OriginContextError):self.resolve(listed,data)

    def test_truncated_or_duplicate_tool_inputs_are_rejected(self):
        for mode in ("truncated","duplicate","wrong_tool","not_assistant"):
            listed,data=fixture();call=data["messages"][0]["tool_calls"][0]
            if mode=="truncated":call["input_truncated"]=True
            if mode=="duplicate":data["messages"][0]["tool_calls"].append(copy.deepcopy(call))
            if mode=="wrong_tool":call["name"]="file_write"
            if mode=="not_assistant":data["messages"][0]["role"]="user"
            with self.subTest(mode=mode),self.assertRaises(o.OriginContextError):self.resolve(listed,data)

    def test_wrong_session_response_and_result_id_are_rejected(self):
        for mode in ("wrong_session","wrong_result"):
            listed,data=fixture()
            if mode=="wrong_session":data["session_id"]="another"
            else:data["messages"][1]["tool_results"][0]["tool_use_id"]="different"
            with self.assertRaises(o.OriginContextError):self.resolve(listed,data)

    def test_shell_injection_cannot_be_an_exact_prepare_anchor(self):
        for command in ['echo x | python3 -B "$HOME/.ictrl/runtime/task_session.py" prepare','python3 -B "$HOME/.ictrl/runtime/task_session.py" prepare || true','python3 -B /tmp/task_session.py prepare']:
            self.assertFalse(o.is_prepare_command(command,TASK,NONCE))
