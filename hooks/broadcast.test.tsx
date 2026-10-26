// Tests of the /broadcast mod (run: `claude plugin test .`, a Claude Code with mods). `process.run` is stubbed; nothing
// is sent to a real hub. Each test loads the module afresh.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { broadcastArgv, isBroadcastCommand, parseBroadcastArgs } from './broadcast'

const PLUGIN: string = 'delamain'
const REGISTERED = () => ({ value: { command: 'broadcast' } })
const ran = (stdout: string, exitCode = 0, stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
const run = ($: Engine, args = '', command = 'broadcast') =>
  $.command.run({ command, args, origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 120 } })

test('leading flags become CLI flags, the rest of the line is the text after --', async () => {
  expect(parseBroadcastArgs('--urgent stop merging')).toEqual({ flags: ['--urgent'], text: 'stop merging' })
  expect(parseBroadcastArgs('  --this-home --exclude core-c   release is out ')).toEqual({ flags: ['--this-home', '--exclude', 'core-c'], text: 'release is out' })
  expect(parseBroadcastArgs('--exclude=web hi')).toEqual({ flags: ['--exclude', 'web'], text: 'hi' })
  expect(parseBroadcastArgs('"quoted --urgent text"')).toEqual({ flags: [], text: 'quoted --urgent text' })
  expect(parseBroadcastArgs('hello --urgent')).toEqual({ flags: [], text: 'hello --urgent' }) // a flag after the text is text
  expect(parseBroadcastArgs('-- --urgent is the text')).toEqual({ flags: [], text: '--urgent is the text' })
  expect(parseBroadcastArgs('--rm -rf')).toEqual({ flags: [], text: '--rm -rf' }) // not a flag of the CLI: text
  expect(parseBroadcastArgs('')).toEqual({ flags: [], text: '' })
  expect(broadcastArgv(parseBroadcastArgs('--urgent go'))).toEqual(['--urgent', '--', 'go'])
  expect(broadcastArgv(parseBroadcastArgs('-x starts with a dash'))).toEqual(['--', '-x starts with a dash'])
  expect(broadcastArgv(parseBroadcastArgs(''))).toEqual(['--dry-run'])
  expect(broadcastArgv(parseBroadcastArgs('--this-home'))).toEqual(['--this-home', '--dry-run'])
  expect(broadcastArgv(parseBroadcastArgs('--dry-run'))).toEqual(['--dry-run'])
})

test("only broadcast and this plugin's <name>:broadcast are answered", async () => {
  expect(isBroadcastCommand('broadcast', PLUGIN)).toBe(true)
  expect(isBroadcastCommand(`${PLUGIN}:broadcast`, PLUGIN)).toBe(true)
  expect(isBroadcastCommand('other:broadcast', PLUGIN)).toBe(false)
  expect(isBroadcastCommand('broadcasts', PLUGIN)).toBe(false)
})

test('/broadcast text runs bin/broadcast with the flags and the text, and answers with its summary', async ($, on) => {
  const calls: string[][] = []
  on('command.register', REGISTERED)
  on('process.run', ($, e) => (calls.push([...e.argv]), ran('ok   core-c\nbroadcast as [owner] to @hub: sent 1, failed 0, skipped 0\n')))
  const answer = await run($, '--urgent release 1.0.20 is out')
  expect(calls.length).toBe(1)
  expect(calls[0][0]).toMatch(/\/bin\/broadcast$/)
  expect(calls[0].slice(1)).toEqual(['--urgent', '--', 'release 1.0.20 is out'])
  expect(answer.text).toContain('sent 1, failed 0')
})

test('bare /broadcast lists the recipients with --dry-run and sends nothing', async ($, on) => {
  const calls: string[][] = []
  on('command.register', REGISTERED)
  on('process.run', ($, e) => (calls.push([...e.argv]), ran('plan core-c\nbroadcast as [owner] to @hub: would send 1, failed 0, skipped 0\n')))
  const answer = await run($, '')
  expect(calls[0].slice(1)).toEqual(['--dry-run'])
  expect(answer.text).toContain('would send 1')
})

test('a failed recipient is reported with the exit code and the CLI output', async ($, on) => {
  on('command.register', REGISTERED)
  on('process.run', () => ran('FAIL web  [headless/claude] Hub web\n     agent send failed\nbroadcast as [owner] to @hub: sent 2, failed 1, skipped 0\n', 1))
  const answer = await run($, 'hello')
  expect(answer.text).toContain('broadcast exited with 1')
  expect(answer.text).toContain('FAIL web')
})

test("another plugin's command passes through to the engine", async ($, on) => {
  let ranCli = 0
  on('command.register', REGISTERED)
  on('process.run', () => (ranCli += 1, ran('')))
  on('command.run', () => ({ text: 'the engine ran it' }))
  expect((await run($, 'hi', 'other:broadcast')).text).toBe('the engine ran it')
  expect(ranCli).toBe(0)
})
