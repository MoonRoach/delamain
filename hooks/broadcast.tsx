// /broadcast, a command of the plugin's mod (hooks/agent-top.tsx registers it): one line to the hub of every open stage, from the prompt of any session.
//
//   /broadcast "text" [--urgent | --question] [--this-home] [--exclude S]   sends through `bin/broadcast`, answers with its summary
//   /broadcast                                                              (bare) lists the recipients, writes nothing (--dry-run)
//
// The module holds no state and writes nothing itself: every send is `bin/broadcast` of the Delamain plugin, which runs
// `tell` per stage. Leading words that are the CLI's flags are passed as flags; everything after them is the text, after
// `--`, so a text may start with a dash. Needs Claude Code with mods (2.1.287+); elsewhere the console `broadcast` stays.
import type { EngineInterface } from 'claude-code'

type Api = EngineInterface

const CALL_TIMEOUT_MS = 150000 // the CLI gives each tell 120 s, eight at a time
const FLAGS = new Set(['--urgent', '--question', '--this-home', '--include-self', '--dry-run'])

export type BroadcastArgs = { flags: string[]; text: string }

/** Leading flags (and `--exclude S` / `--exclude=S`) become CLI flags; the rest of the line, as typed, is the text. */
export function parseBroadcastArgs(raw: string): BroadcastArgs {
  const flags: string[] = []
  let rest = raw.trim()
  for (;;) {
    const m = /^(\S+)(?:\s+|$)/.exec(rest)
    if (!m) break
    const word = m[1]
    if (word === '--') {
      rest = rest.slice(m[0].length)
      break
    }
    if (FLAGS.has(word)) {
      flags.push(word)
    } else if (word.startsWith('--exclude=') && word.length > '--exclude='.length) {
      flags.push('--exclude', word.slice('--exclude='.length))
    } else if (word === '--exclude') {
      const n = /^--exclude\s+(\S+)(?:\s+|$)/.exec(rest)
      if (!n) break
      flags.push('--exclude', n[1])
      rest = rest.slice(n[0].length)
      continue
    } else {
      break
    }
    rest = rest.slice(m[0].length)
  }
  const text = rest.replace(/^(["'])([\s\S]*)\1$/, '$2').trim() // one pair of quotes around the whole text is the typing's, not the line's
  return { flags, text }
}

/** The CLI's argv after the binary: bare → --dry-run (who would get it). */
export function broadcastArgv(a: BroadcastArgs): string[] {
  if (a.text === '') return a.flags.includes('--dry-run') ? a.flags : [...a.flags, '--dry-run']
  return [...a.flags, '--', a.text]
}

export function isBroadcastCommand(command: string, pluginName: string): boolean {
  return command === 'broadcast' || command === `${pluginName}:broadcast`
}

async function runBroadcast($: Api, argv: string[]): Promise<string> {
  const bin = `${$.plugin.root}/bin/broadcast`
  try {
    const r = await $.process.run([bin, ...argv], { timeoutMs: CALL_TIMEOUT_MS, env: { PYTHONDONTWRITEBYTECODE: '1' } })
    if (r.exitCode === 127) return `broadcast cannot run (${bin})`
    const out = [r.stdout.trim(), r.stderr.trim()].filter(s => s !== '').join('\n')
    if (r.exitCode === 0) return out || 'broadcast: done'
    return `broadcast exited with ${r.exitCode}${r.exitCode === 1 ? ' (a recipient did not take the line, or there is none)' : ''}\n${out}`
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (/ENOENT|no such file|not found|cannot start|spawn/i.test(msg)) return `broadcast is missing (${bin})`
    // a killed call may have reached some hubs already: never suggest sending again blind
    if (/still running|timed? ?out/i.test(msg)) return `broadcast gave no answer in ${CALL_TIMEOUT_MS / 1000} s; some hubs may have the line — look at their journals before sending again`
    return `broadcast: ${msg}`
  }
}

/** Registers /broadcast; called from the module's session.start (a plugin has one hooks module: hooks/agent-top.tsx). */
export async function registerBroadcast($: Api): Promise<void> {
  try {
    await $.command.register({
      name: 'broadcast',
      description: 'Write one line to the hub of every open stage (bare: list who would get it)',
      argumentHint: '"text" [--urgent|--question] [--this-home] [--exclude S]',
      immediate: true,
    })
  } catch (err) {
    $.ui.log(`broadcast: could not register /broadcast: ${err instanceof Error ? err.message : String(err)}`, { to: 'debug' })
  }
}

/** The answer to /broadcast `args`: the CLI's summary (bare: the recipients, nothing sent). */
export async function answerBroadcast($: Api, args: string): Promise<string> {
  return runBroadcast($, broadcastArgv(parseBroadcastArgs(args)))
}
