import contextlib
import hashlib
import importlib.util
import json
import os
import types
import threading
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "ictrl-ready" / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("task_session", SCRIPTS / "task_session.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class Tests(unittest.TestCase):
    def test_validation(self):
        for command in ({"method":"automation_begin", "params":{}}, {"method":"tap", "params":{"automation_session":"x"}}, {"method":"../x", "params":{}}, {"method":"tap", "params":{"v":float("nan")}}):
            with self.assertRaises(ValueError): m.validate(command)
        self.assertTrue(m.validate({"method":"tap", "params":{}}))

    def test_read_limit(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)/"x"; p.write_text("12345")
            with self.assertRaises(ValueError): m.read(p, 4)

    def test_worker_single_call_and_cleanup_order(self):
        events = []
        class Session:
            def __init__(self, raw, **kw): self.local_deadline = 1000
            def __enter__(self): events.append("begin"); return self
            def __exit__(self, *args): events.append("end")
            def call(self, method, params): events.append("call"); return {"ok":True}
        @contextlib.contextmanager
        def managed(*args):
            events.append("lock")
            class State: restore_status="restored"
            try: yield State()
            finally: events.append("restore")
        @contextlib.contextmanager
        def lock(*args): yield
        with tempfile.TemporaryDirectory() as td:
            base=Path(td); task="a"*32; directory=base/task; directory.mkdir()
            m.atomic(directory/"state", {"phase":"starting", "pid":os.getpid(), "store_key":"device:abc", "client_path":None})
            command={"method":"tap", "params":{}}; raw=m.validate(command); req="b"*32
            m.atomic(directory/("req-"+req+".json"), {"id":req, "hash":hashlib.sha256(raw).hexdigest(), "command":command, "not_after":500})
            ticks=iter([0, 0, 0, 1000, 1000])
            fake=types.SimpleNamespace(LOCK_EX=1,LOCK_NB=2,LOCK_UN=4,flock=lambda *a:None)
            with mock.patch.dict(sys.modules,{"fcntl":fake}), mock.patch.object(m,"locked",lock):
                m.worker(base, task, "device:abc", loader=lambda *a,**k:(None,True), session_cls=Session, manager_cls=lambda *a:None, managed=managed, clock=lambda:next(ticks), sleep=lambda n:None)
            self.assertEqual(events,["begin","lock","call","restore","end"])
            self.assertEqual(m.read(directory/("result-"+req))["status"],"complete")
            self.assertEqual(m.read(directory/"state")["phase"],"complete")

    def test_expired_request_never_calls(self):
        events=[]
        class Session:
            def __init__(self, raw, **kw): self.local_deadline=1000
            def __enter__(self): return self
            def __exit__(self,*a): pass
            def call(self,*a): events.append("call")
        @contextlib.contextmanager
        def managed(*a):
            class State: restore_status="restored"
            yield State()
        @contextlib.contextmanager
        def lock(*a): yield
        fake=types.SimpleNamespace(LOCK_EX=1,LOCK_NB=2,LOCK_UN=4,flock=lambda *a:None)
        with tempfile.TemporaryDirectory() as td:
            base=Path(td); task="a"*32; d=base/task; d.mkdir(); req="b"*32
            m.atomic(d/"state", {"phase":"starting","pid":os.getpid(),"store_key":"device:abc","client_path":None})
            command={"method":"tap","params":{}}
            m.atomic(d/("req-"+req+".json"), {"id":req,"hash":hashlib.sha256(m.validate(command)).hexdigest(),"command":command,"not_after":1})
            ticks=iter([2,2,1000,1000])
            with mock.patch.dict(sys.modules,{"fcntl":fake}), mock.patch.object(m,"locked",lock):
                m.worker(base,task,"device:abc",loader=lambda *a,**k:(None,True),session_cls=Session,manager_cls=lambda *a:None,managed=managed,clock=lambda:next(ticks),sleep=lambda n:None)
            self.assertEqual(events,[])
            self.assertEqual(m.read(d/("result-"+req))["status"],"expired")

    def test_duplicate_request_does_not_enqueue_and_hash_conflict(self):
        @contextlib.contextmanager
        def lock(*a): yield
        with tempfile.TemporaryDirectory() as td:
            base=Path(td); task="a"*32; req="b"*32; d=base/task; d.mkdir()
            m.atomic(base/"active",task); m.atomic(d/"state",{"phase":"running","pid":os.getpid()})
            command={"method":"tap","params":{}}
            m.atomic(d/("record-"+req),{"hash":hashlib.sha256(m.validate(command)).hexdigest()})
            m.atomic(d/("result-"+req),{"status":"complete","response":{"ok":True}})
            with mock.patch.object(m,"locked",lock):
                out=m.request_call(base,task,req,command,base/"one",1)
                self.assertEqual(out["status"],"complete")
                self.assertFalse((d/("req-"+req+".json")).exists())
                with self.assertRaises(ValueError): m.request_call(base,task,req,{"method":"swipe","params":{}},base/"two",1)

    def test_duplicate_worker_does_not_touch_state(self):
        @contextlib.contextmanager
        def lock(*a): yield
        def flock(fd,flags):
            if flags == 3: raise BlockingIOError()
        fake=types.SimpleNamespace(LOCK_EX=1,LOCK_NB=2,LOCK_UN=4,flock=flock)
        with tempfile.TemporaryDirectory() as td:
            base=Path(td); task="a"*32; d=base/task; d.mkdir()
            m.atomic(d/"state", {"phase":"running","pid":os.getpid()})
            with mock.patch.dict(sys.modules,{"fcntl":fake}), mock.patch.object(m,"locked",lock):
                m.worker(base,task,"device:abc",loader=lambda *a,**k:self.fail("transport called"))
            self.assertEqual(m.read(d/"state")["phase"],"running")

    def test_completed_start_same_id_never_spawns(self):
        @contextlib.contextmanager
        def lock(*a): yield
        with tempfile.TemporaryDirectory() as td:
            base=Path(td); task="a"*32; d=base/task; d.mkdir()
            m.atomic(base/"active",task)
            m.atomic(d/"state", {"phase":"complete", "pid":1, "restore":"restored", "store_key":"device:abc", "client_path":None})
            with mock.patch.object(m,"locked",lock), mock.patch.object(m.subprocess,"Popen",side_effect=AssertionError("spawn")):
                self.assertEqual(m.start(base,task,"device:abc")["status"],"complete")
                with self.assertRaises(ValueError): m.start(base,task,"device:other")

    def test_cleanup_budget_after_deadline(self):
        session=types.SimpleNamespace(local_deadline=100)
        self.assertEqual(m.transport_budget("automation_end",session,False,lambda:101),5)
        with self.assertRaises(TimeoutError): m.transport_budget("tap",session,False,lambda:101)
        with self.assertRaises(TimeoutError): m.transport_budget("tap",session,True,lambda:26)

    def test_stopping_and_single_pending_reject_calls(self):
        @contextlib.contextmanager
        def lock(*a): yield
        with tempfile.TemporaryDirectory() as td:
            base=Path(td); task="a"*32; d=base/task; d.mkdir(); m.atomic(base/"active",task)
            cmd={"method":"tap","params":{}}
            with mock.patch.object(m,"locked",lock):
                m.atomic(d/"state",{"phase":"stopping","pid":os.getpid()})
                with self.assertRaises(RuntimeError): m.request_call(base,task,"c"*32,cmd,base/"one",1)
                m.atomic(d/"state",{"phase":"running","pid":os.getpid()})
                m.atomic(d/("record-"+"b"*32),{"hash":"unused"})
                with self.assertRaises(RuntimeError): m.request_call(base,task,"c"*32,cmd,base/"two",1)

    def test_request_deadline_blocks_unsent_ui(self):
        session=types.SimpleNamespace(local_deadline=1000)
        with self.assertRaises(TimeoutError): m.transport_budget("tap",session,True,lambda:51,50)
        self.assertEqual(m.transport_budget("automation_end",session,False,lambda:1001,50),5)

    def test_status_remaining_and_wait_default(self):
        with tempfile.TemporaryDirectory() as td:
            d=Path(td); m.atomic(d/"state",{"phase":"running","pid":os.getpid(),"body_deadline":150})
            with mock.patch.object(m.time,"monotonic",return_value=100):
                self.assertEqual(m.public_status(d)["remaining_body_seconds"],50)
        self.assertEqual(m.request_call.__defaults__,(90,))

    def test_cancel_before_loading(self):
        @contextlib.contextmanager
        def lock(*a): yield
        fake=types.SimpleNamespace(LOCK_EX=1,LOCK_NB=2,LOCK_UN=4,flock=lambda *a:None)
        with tempfile.TemporaryDirectory() as td:
            base=Path(td); task="a"*32; d=base/task; d.mkdir()
            m.atomic(d/"state",{"phase":"starting","pid":os.getpid(),"store_key":"device:abc","client_path":None})
            m.atomic(d/"stop",{"stop_requested":True})
            with mock.patch.dict(sys.modules,{"fcntl":fake}), mock.patch.object(m,"locked",lock):
                m.worker(base,task,"device:abc",loader=lambda *a,**k:self.fail("loader called"))
            self.assertEqual(m.read(d/"state")["restore"],"not_required")

    def test_finish_during_begin_does_not_wait_for_network_and_failed_end_is_unknown(self):
        gate=threading.Lock(); begin_entered=threading.Event(); finish_begin=threading.Event(); events=[]
        @contextlib.contextmanager
        def lock(*a):
            with gate: yield
        fake=types.SimpleNamespace(LOCK_EX=1,LOCK_NB=2,LOCK_UN=4,flock=lambda *a:None)
        class Session:
            def __init__(self,*a,**k): self.local_deadline=1000; self.cleanup_error=None
            def __enter__(self):
                events.append("begin"); begin_entered.set()
                if not finish_begin.wait(2): raise AssertionError("finish could not obtain lock")
                return self
            def __exit__(self, kind, error, tb):
                events.append("end"); self.cleanup_error=RuntimeError("uncertain")
                error.automation_cleanup_error=self.cleanup_error
        @contextlib.contextmanager
        def managed(*a):
            events.append("managed"); yield
        with tempfile.TemporaryDirectory() as td:
            base=Path(td); task="a"*32; d=base/task; d.mkdir()
            m.atomic(d/"state",{"phase":"starting","pid":os.getpid(),"store_key":"device:abc","client_path":None})
            with mock.patch.dict(sys.modules,{"fcntl":fake}), mock.patch.object(m,"locked",lock):
                thread=threading.Thread(target=m.worker,args=(base,task,"device:abc"),kwargs={"loader":lambda *a,**k:(None,True),"session_cls":Session,"manager_cls":lambda *a:None,"managed":managed})
                thread.start(); self.assertTrue(begin_entered.wait(2))
                acquired=gate.acquire(timeout=1); self.assertTrue(acquired,"base lock held during Begin")
                try: m.atomic(d/"stop",{"stop_requested":True})
                finally: gate.release(); finish_begin.set()
                thread.join(3); self.assertFalse(thread.is_alive())
            self.assertEqual(events,["begin","end"])
            state=m.read(d/"state"); self.assertEqual(state["phase"],"unknown"); self.assertEqual(state["restore"],"pending")

if __name__ == "__main__": unittest.main()
