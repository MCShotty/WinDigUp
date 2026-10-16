#!/usr/bin/env python3
"""Real service scheduling with explicitly synthetic vectors; never a hardware/model benchmark."""
import argparse
import json
import os
from pathlib import Path
import platform
import queue
import subprocess
import sys
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="digup-search-") as directory:
        root = Path(directory)
        bundle = root / "bundle"
        bundle.mkdir()
        (bundle / "manifest.json").write_text("{}")
        requests = root / "requests.jsonl"
        env = os.environ.copy()
        env.update(DIGUP_ACCELERATOR="openvino-npu", DIGUP_OPENVINO_PYTHON=sys.executable,
                   DIGUP_OPENVINO_MODELS=str(bundle), DIGUP_APP_TEST_LOG=str(requests),
                   DIGUP_APP_TEST_DELAY="0.75",
                   DIGUP_APP_TEST_CRASH_ON="force worker crash",
                   DIGUP_OPENVINO_WORKER=str(Path(__file__).resolve().parents[1] / "tests/applications/synthetic-worker.py"))
        replies = queue.Queue()
        with (root / "stderr.log").open("w") as log:
            service = subprocess.Popen([str(args.helper.resolve()), "search-service", "--index", str(root / "index")],
                                       env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                                       text=True, encoding="utf-8")
            def read():
                for line in service.stdout:
                    replies.put((time.perf_counter(), json.loads(line)))
            threading.Thread(target=read, daemon=True).start()
            def send(identifier, **request):
                service.stdin.write(json.dumps(dict(id=identifier, **request)) + "\n")
                service.stdin.flush()
            def wait(identifier, timeout=20):
                if identifier in received:
                    return received[identifier]
                deadline = time.perf_counter() + timeout
                while time.perf_counter() < deadline:
                    at, reply = replies.get(timeout=max(.01, deadline - time.perf_counter()))
                    received[reply.get("id")] = (at, reply)
                    if identifier in received:
                        return received[identifier]
                raise AssertionError(f"No reply for {identifier}")
            received = {}
            try:
                send(1, op="prewarm")
                wait(1)
                send(2, op="embed_ahead", q="blocked query", session="panel", generation=1)
                deadline = time.perf_counter() + 10
                while not requests.exists() and time.perf_counter() < deadline:
                    time.sleep(.005)
                assert requests.exists(), "Synthetic encoder did not start"
                start = time.perf_counter()
                send(3, op="search", q="keyword", meaning=False, session="window", generation=1)
                for generation in range(2, 14):
                    send(10 + generation, op="embed_ahead", q=f"obsolete {generation}",
                         session="panel", generation=generation)
                at, lexical = wait(3)
                lexical_ms = (at - start) * 1000
                wait(23)
                while len([k for k in received if isinstance(k, int) and k >= 12]) < 12:
                    at, reply = replies.get(timeout=20)
                    received[reply.get("id")] = (at, reply)
                operations = [json.loads(line) for line in requests.read_text().splitlines()]
                report = dict(schemaVersion=1, synthetic=True, physicalAcceleratorValidated=False,
                              machine=platform.platform(), helper=str(args.helper.resolve()),
                              workload="750 ms synthetic encoder call, concurrent keyword search, 12 newer generations",
                              lexicalWhileEncodingMs=round(lexical_ms, 2), encoderCalls=len(operations),
                              superseded=sum(r.get("status") == "superseded" for _, r in received.values()),
                              keywordReply=lexical)
                print(json.dumps(report, indent=2))
                if args.output:
                    args.output.write_text(json.dumps(report, indent=2) + "\n")
                if not args.baseline:
                    assert lexical_ms < 250, "Keyword search waited for inference"
                    assert len(operations) <= 3, "Obsolete embedding requests accumulated"
                    assert report["superseded"] >= 10, "Superseded requests were not completed"
                    send(30,op="apps_catalog",revision="shared",documents=[])
                    wait(30)
                    before=len(operations)
                    send(31,op="search",q="shared query",meaning=True,session="window",generation=2)
                    send(32,op="apps_search",q="shared query",revision="shared",session="apps",generation=1)
                    wait(32);wait(31)
                    assert len(requests.read_text().splitlines())==before+1,"Files and apps encoded the same query twice"
                    send(40,op="search",q="force worker crash",meaning=True,session="window",generation=3)
                    wait(40)
                    send(41,op="apps_status")
                    state=wait(41)[1]
                    assert state["encoder"]=="unavailable",state
                    count=len(requests.read_text().splitlines())
                    send(42,op="embed_ahead",q="must not restart",session="window",generation=4)
                    wait(42)
                    assert len(requests.read_text().splitlines())==count,"Failed encoder restarted automatically"
                    send(43,op="search",q="still searchable",meaning=False,session="window",generation=5)
                    assert wait(43)[1].get("ok") is not False
                    print("PASS: shared file/app query cache, crashed encoder isolation, persistent failure and keyword recovery")
                    files=root/"files"
                    files.mkdir()
                    (files/"lease.txt").write_text("Foreground priority should yield before the next document embedding. "*100)
                    events=queue.Queue()
                    indexer=subprocess.Popen([str(args.helper.resolve()),"index-service",str(files),"--index",str(root/"lease-index"),"--linger","0.1","--backfill"],
                        env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,encoding="utf-8")
                    def read_index():
                        for line in indexer.stdout:
                            events.put(json.loads(line))
                    threading.Thread(target=read_index,daemon=True).start()
                    try:
                        before=len(requests.read_text().splitlines())
                        indexer.stdin.write("foreground\n");indexer.stdin.flush()
                        deadline=time.perf_counter()+15
                        while True:
                            event=events.get(timeout=max(.01,deadline-time.perf_counter()))
                            if event.get("event")=="foreground_hold" and event.get("state")=="waiting":
                                break
                            assert time.perf_counter()<deadline,"Indexer did not yield to the foreground lease"
                        assert len(requests.read_text().splitlines())==before,"Indexer submitted inference during the hold"
                        for _ in range(3):
                            indexer.stdin.write("foreground\n");indexer.stdin.flush();time.sleep(.25)
                        assert len(requests.read_text().splitlines())==before
                        deadline=time.perf_counter()+10
                        resumed=False
                        while True:
                            event=events.get(timeout=max(.01,deadline-time.perf_counter()))
                            resumed |= event.get("event")=="foreground_hold" and event.get("state")=="resumed"
                            if event.get("event")=="file":
                                assert event.get("state") in ("done","partial"),event
                                break
                            assert time.perf_counter()<deadline,"Expired foreground lease did not resume indexing"
                        assert resumed
                        print("PASS: real indexing helper yields before inference, renews its foreground lease and resumes automatically after expiry")
                    finally:
                        indexer.terminate()
                        try:
                            indexer.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            indexer.kill();indexer.wait()
                if not args.baseline:
                    idle_env=dict(env,DIGUP_APP_TEST_DELAY="0")
                    idle=subprocess.Popen([str(args.helper.resolve()),"search-service","--index",str(root/"idle-index"),"--encoder-idle","0.1"],
                        env=idle_env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,encoding="utf-8")
                    def idle_call(identifier,**fields):
                        idle.stdin.write(json.dumps(dict(id=identifier,**fields))+"\n");idle.stdin.flush()
                        for line in idle.stdout:
                            reply=json.loads(line)
                            if reply.get("id")==identifier:
                                return reply
                        raise AssertionError("Idle helper exited")
                    try:
                        idle_call(1,op="prewarm")
                        time.sleep(1.5)
                        assert idle_call(2,op="status")["encoder"]=="stopped"
                        count=len(requests.read_text().splitlines())
                        idle_call(3,op="search",q="passive refresh",meaning=True,passive=True)
                        assert idle_call(4,op="status")["encoder"]=="stopped"
                        assert len(requests.read_text().splitlines())==count,"Passive refresh woke an idle encoder"
                        idle_call(5,op="search",q="user requested query",meaning=True)
                        assert len(requests.read_text().splitlines())==count+1
                        print("PASS: idle unload, passive refresh without model wake and explicit-query resumption")
                    finally:
                        idle.terminate()
                        try:
                            idle.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            idle.kill();idle.wait()
            finally:
                service.terminate()
                try:
                    service.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    service.kill()
                    service.wait()


if __name__ == "__main__":
    main()
