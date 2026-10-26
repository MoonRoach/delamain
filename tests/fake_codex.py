#!/usr/bin/env python3
"""Codex CLI fixture: real flag grammar, generated thread ID, raw JSONL."""
import json, os, sys, time, uuid
from pathlib import Path
args = sys.argv[1:]
if args == ['--version']:
 print('codex-cli 0.155.1'); sys.exit(0)
if not args or args[0] != 'exec':
 sys.exit('expected exec')
resume = len(args)>1 and args[1]=='resume'
sid = args[2] if resume else str(uuid.uuid4())
prompt = sys.stdin.read() if args[-1]=='-' else args[-1]  # `-` = read the prompt from stdin, as the real CLI does
with open('codex-argv.jsonl','a') as f:
 f.write(json.dumps(args[:-1])+'\n')
with open('codex-env.jsonl','a') as f:
 f.write(json.dumps({k:os.environ.get(k) for k in ('AGENT_HUB_ENGINE','CODEX_THREAD_ID','CLAUDE_CODE_SESSION_ID','HUB_BIN','AGENT_HUB_HOME','AGENT_HUB_SLOT')})+'\n')
with open('codex-prompts.log','a') as f:
 f.write(prompt+'\n')
if os.environ.get('FAKE_CODEX')=='die':
 sys.exit('unsupported option')
if os.environ.get('FAKE_CODEX')=='hang':
 time.sleep(60);sys.exit(0)
def emit(x):
 print(json.dumps(x),flush=True)
emit({'type':'thread.started','thread_id':sid})
emit({'type':'turn.started'})
time.sleep(float(os.environ.get('FAKE_CODEX_HOLD','0.2')))
if os.environ.get('FAKE_CODEX_READ_INBOX'):
 emit({'type':'item.completed','item':{'type':'command_execution','id':'read','command':'cat inbox.md','exit_code':0,'aggregated_output':'read'}})
final=os.environ.get('FAKE_CODEX_FINAL','fixture answered')
emit({'type':'item.completed','item':{'id':'answer','type':'agent_message','text':final}})
if os.environ.get('FAKE_CODEX')=='error':
 emit({'type':'turn.failed','error':{'message':'fixture API failure'}});sys.exit(1)
emit({'type':'turn.completed','usage':{'input_tokens':120,'cached_input_tokens':20,'output_tokens':10}})
