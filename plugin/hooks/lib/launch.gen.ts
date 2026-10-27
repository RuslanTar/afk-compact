// GEN by tools/build from brand.json. Do not edit; edit the source and run tools/build.
import type { EngineInterface } from 'claude-code'

/** The env the restart launcher exports its launch folder in (tools/build launch_env). */
export const LAUNCH_ENV = "AFK_COMPACT_LAUNCH"

/** The launch folder of the restart launcher this session runs under, or undefined. */
export async function launchDir($: EngineInterface): Promise<string | undefined> {
  const v = await $.env.get('AFK_COMPACT_LAUNCH')
  return typeof v === 'string' && v !== '' ? v : undefined
}
