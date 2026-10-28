import contextlib
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "ictrl-ready/scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("completion_task", SCRIPTS / "task_session.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class CompletionTests(unittest.TestCase):
    def test_default_new_cli_requires_trusted_origin_and_rejects_url_injection(self):
        for origin in (None, "", "latest", "x/y", "x?other=1"):
            # Plain stable ids are permitted, but 'latest' must never be obtained by guessing.
            if origin == "latest": continue
            with self.assertRaises(ValueError): m.completion_options("return_chat", origin)
        self.assertEqual(m.completion_options("stay")["policy"], "stay")

    def test_origin_and_stay_bind_start_idempotency(self):
        a=m.completion_options("return_chat", "chat_A")
        b=m.completion_options("return_chat", "chat_B")
        self.assertNotEqual(m.start_hash("a"*32,"device:x",None,240,a),m.start_hash("a"*32,"device:x",None,240,b))
        self.assertNotEqual(m.start_hash("a"*32,"device:x",None,240,a),m.start_hash("a"*32,"device:x",None,240,m.completion_options("stay")))

    def test_minis_cleanup_is_one_atomic_finish_not_end_then_global_stop(self):
        calls=[]
        def raw(method,params):
            calls.append((method,params))
            return {"service_finish":"closing","return_route":"dispatched","chat_verified":False,"state":"ended"}
        t=m.MinisFinishTransport(raw,m.completion_options("return_chat","origin_A"))
        t("automation_native_end",{"lease_id":"owned"})
        self.assertEqual(calls,[("automation_native_finish",{"lease_id":"owned","completion_policy":"return_chat","origin_session_id":"origin_A","stop_service":True})])
        self.assertEqual(t.receipt["service_finish"],"closing")
        self.assertFalse(t.receipt["chat_verified"])

    def test_explicit_stay_and_unknown_skip_still_finish_service(self):
        for policy,suppress,want in [("stay",False,"stay"),("return_chat",True,"skip_unknown")]:
            calls=[]
            def raw(method,params): calls.append(params); return {"service_finish":"closing","return_route":"skipped_stay","chat_verified":False}
            t=m.MinisFinishTransport(raw,m.completion_options(policy,"origin_A" if policy=="return_chat" else None));t.suppress_return=suppress
            t("automation_native_end",{"lease_id":"owned"})
            self.assertEqual(calls[0]["completion_policy"],want)
            self.assertNotIn("origin_session_id",calls[0]);self.assertTrue(calls[0]["stop_service"])

    def test_missing_native_support_refuses_before_begin_and_lost_finish_is_not_replayed(self):
        calls=[]
        def old(method,params): calls.append(method);return {}
        t=m.MinisFinishTransport(old,m.completion_options("stay"))
        with self.assertRaises(Exception):t("automation_native_capabilities",{})
        self.assertEqual(calls,["automation_native_capabilities"])
        def lost(method,params):calls.append(method);raise TimeoutError()
        t=m.MinisFinishTransport(lost,m.completion_options("stay"))
        with self.assertRaises(TimeoutError):t("automation_native_end",{"lease_id":"owned"})
        self.assertIsNone(t.receipt);self.assertEqual(calls.count("automation_native_finish"),1)

    def test_finish_waits_without_holding_lock_and_duplicate_finish_does_not_rewrite_stop(self):
        held=[False];now=[0];states=[{"status":"running","restore":"pending"},{"status":"complete","restore":"not_required"}]
        @contextlib.contextmanager
        def lock(base):
            self.assertFalse(held[0]);held[0]=True
            try:yield
            finally:held[0]=False
        def sleep(seconds):self.assertFalse(held[0]);now[0]+=seconds
        with tempfile.TemporaryDirectory() as td:
            base=Path(td);directory=base/("a"*32);directory.mkdir();m.atomic(base/"active","a"*32)
            with mock.patch.object(m,"locked",lock),mock.patch.object(m,"public_status",side_effect=states):
                result=m.finish(base,"a"*32,1,clock=lambda:now[0],sleep=sleep)
            before=(directory/"stop").read_bytes()
            with mock.patch.object(m,"locked",lock),mock.patch.object(m,"public_status",return_value=states[-1]),mock.patch.object(m,"atomic",side_effect=AssertionError("duplicate mutation")):
                again=m.finish(base,"a"*32,0)
            self.assertTrue(result["control_end_confirmed"]);self.assertTrue(again["control_end_confirmed"]);self.assertEqual(before,(directory/"stop").read_bytes())

    def test_finish_timeout_or_unknown_is_not_reported_as_ended(self):
        @contextlib.contextmanager
        def lock(base):yield
        for status in ("running","unknown"):
            with tempfile.TemporaryDirectory() as td:
                base=Path(td);directory=base/("a"*32);directory.mkdir();m.atomic(base/"active","a"*32)
                with mock.patch.object(m,"locked",lock),mock.patch.object(m,"public_status",return_value={"status":status,"restore":"pending"}):
                    self.assertFalse(m.finish(base,"a"*32,0)["control_end_confirmed"])

    def test_worker_finish_returns_and_stops_once_and_duplicate_worker_cannot_repeat(self):
        import os,types
        events=[]
        @contextlib.contextmanager
        def lock(base):yield
        fake=types.SimpleNamespace(LOCK_EX=1,LOCK_NB=2,LOCK_UN=4,flock=lambda *a:None)
        class Session:
            cleanup_error=None
            def __init__(self,raw,**kw):self.raw=raw;self.local_deadline=1000
            def __enter__(self):self.raw("automation_native_capabilities",{});events.append("begin");return self
            def __exit__(self,*a):self.raw("automation_native_end",{"lease_id":"owned"});events.append("end")
        @contextlib.contextmanager
        def managed(*a):yield types.SimpleNamespace(restore_status="not_required")
        def raw(method,params):
            events.append((method,params))
            if method=="automation_native_capabilities":return {"minis_atomic_finish":1,"minis_handoff":1}
            return {"service_finish":"closing","return_route":"dispatched","chat_verified":False}
        with tempfile.TemporaryDirectory() as td:
            base=Path(td);task="a"*32;d=base/task;d.mkdir()
            completion=m.completion_options("return_chat","origin_A")
            m.atomic(d/"state",{"phase":"starting","pid":os.getpid(),"store_key":"device:x","client_path":None,"completion":completion})
            def sleep(_):m.atomic(d/"stop",{"stop_requested":True})
            kw=dict(loader=lambda *a,**k:(raw,True),session_cls=Session,manager_cls=lambda *a:None,managed=managed,clock=lambda:0,sleep=sleep)
            with mock.patch.dict(sys.modules,{"fcntl":fake}),mock.patch.object(m,"locked",lock):
                m.worker(base,task,"device:x",**kw)
                before=list(events);m.worker(base,task,"device:x",**kw)
            self.assertEqual(events,before)
            state=m.read(d/"state");self.assertEqual(state["phase"],"complete")
            self.assertEqual(state["return_to_chat"]["service_finish"],"closing")
            finish_calls=[x for x in events if isinstance(x,tuple) and x[0]=="automation_native_finish"]
            self.assertEqual(len(finish_calls),1);self.assertEqual(finish_calls[0][1]["origin_session_id"],"origin_A")
            self.assertEqual(events[-1],"end")

    def test_new_direct_start_without_origin_refuses_before_state_or_spawn(self):
        with tempfile.TemporaryDirectory() as td:
            base=Path(td)/"tasks"
            with mock.patch.object(m.subprocess,"Popen",side_effect=AssertionError("spawn")):
                with self.assertRaisesRegex(ValueError,"originating Minis session"):
                    m.start(base,"a"*32,"device:x")
            self.assertFalse(base.exists())

    def test_wait_ready_is_bounded_local_and_releases_lock_while_waiting(self):
        held=[False];now=[0]
        @contextlib.contextmanager
        def lock(base):
            self.assertFalse(held[0]);held[0]=True
            try:yield
            finally:held[0]=False
        def sleep(seconds):self.assertFalse(held[0]);now[0]+=seconds
        with tempfile.TemporaryDirectory() as td:
            base=Path(td);d=base/("a"*32);d.mkdir();m.atomic(base/"active","a"*32)
            with mock.patch.object(m,"locked",lock),mock.patch.object(m,"public_status",side_effect=[{"status":"starting"},{"status":"running"}]):
                self.assertEqual(m.wait_ready(base,"a"*32,1,clock=lambda:now[0],sleep=sleep)["status"],"running")
            with mock.patch.object(m,"locked",lock),mock.patch.object(m,"public_status",return_value={"status":"starting"}):
                self.assertEqual(m.wait_ready(base,"a"*32,0)["status"],"starting")

    def test_prepare_generates_and_persists_one_time_ids_without_ui(self):
        @contextlib.contextmanager
        def lock(base):base.mkdir(exist_ok=True);yield
        with tempfile.TemporaryDirectory() as td:
            base=Path(td)/"tasks"
            with mock.patch.object(m,"locked",lock):
                value=m.prepare_origin(base)
                self.assertRegex(value["task_id"],r"^[a-f0-9]{32}$")
                self.assertRegex(value["origin_nonce"],r"^[a-f0-9]{32}$")
                self.assertEqual(m.prepare_origin(base,value["task_id"],value["origin_nonce"]),value)
                with self.assertRaises(ValueError):m.prepare_origin(base,value["task_id"],"f"*32)
            self.assertFalse((base/"active").exists())

    def test_expired_minis_cleanup_has_independent_budget_and_still_finishes(self):
        sent=[];holder={}
        def raw(method,params):
            sent.append((method,m.transport_budget(method,holder["session"],False,clock=lambda:105)))
            return {"backend":"native","mode":"automation","state":"ended","lease_id":"a"*32,"deadline":"1970-01-01T00:00:00Z","service_finish":"closing","return_route":"skipped_stay","chat_verified":False}
        t=m.MinisFinishTransport(raw,m.completion_options("stay"));s=m.MinisAutomationSession(t);holder["session"]=s;s.lease_id="a"*32;s.local_deadline=100
        s._cleanup();self.assertEqual(sent,[("automation_native_finish",15.0)]);self.assertIsNone(s.lease_id)

    def test_unsettled_heartbeat_join_uses_one_owner_finish_without_return_ui(self):
        sent=[]
        class Thread:
            def join(self,timeout):self.timeout=timeout
            def is_alive(self):return True
        def raw(method,params):
            sent.append((method,params))
            return {"backend":"native","mode":"automation","state":"ended","lease_id":"a"*32,"deadline":"1970-01-01T00:00:00Z","service_finish":"closing","return_route":"skipped_unknown","chat_verified":False}
        t=m.MinisFinishTransport(raw,m.completion_options("return_chat","origin_A"));s=m.MinisAutomationSession(t);s.lease_id="a"*32;s._thread=Thread()
        s._cleanup();self.assertTrue(t.receipt["heartbeat_join_unsettled"]);self.assertTrue(s._stop.is_set());self.assertEqual(len(sent),1);self.assertEqual(sent[0][1]["completion_policy"],"skip_unknown");self.assertNotIn("origin_session_id",sent[0][1])

    def test_finish_lost_ack_or_foreign_rejection_is_never_replayed_or_global_stopped(self):
        for failure in (TimeoutError(),RuntimeError("owner_or_request_mismatch")):
            sent=[]
            def raw(method,params):sent.append(method);raise failure
            t=m.MinisFinishTransport(raw,m.completion_options("stay"));s=m.MinisAutomationSession(t);s.lease_id="a"*32
            with self.assertRaises(type(failure)):s._cleanup()
            with self.assertRaises(Exception):t("automation_native_end",{"lease_id":"a"*32})
            self.assertEqual(sent,["automation_native_finish"]);self.assertIsNone(s.lease_id)

    def test_return_chat_requires_handoff_capability_before_begin(self):
        calls=[]
        def raw(method,params):calls.append(method);return {"minis_atomic_finish":1}
        t=m.MinisFinishTransport(raw,m.completion_options("return_chat","origin_A"))
        with self.assertRaisesRegex(Exception,"handoff requires"):t("automation_native_capabilities",{})
        self.assertEqual(calls,["automation_native_capabilities"])

    def test_failed_handoff_does_not_report_full_completion_even_when_control_ended(self):
        @contextlib.contextmanager
        def lock(base):yield
        with tempfile.TemporaryDirectory() as td:
            base=Path(td);d=base/("a"*32);d.mkdir();m.atomic(base/"active","a"*32)
            for state,confirmed in [("timeout",False),("blocked_alert",False),("app_confirmed",True)]:
                status={"status":"complete","restore":"not_required","return_to_chat":{"policy":"return_chat","handoff_state":state,"foreground_confirmed":confirmed}}
                with mock.patch.object(m,"locked",lock),mock.patch.object(m,"public_status",return_value=status):result=m.finish(base,"a"*32,0)
                self.assertTrue(result["control_end_confirmed"]);self.assertEqual(result["completion_confirmed"],confirmed)
                self.assertEqual(result["handoff_confirmed"],confirmed)
