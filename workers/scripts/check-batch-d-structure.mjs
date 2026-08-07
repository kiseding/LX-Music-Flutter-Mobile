import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const repo = resolve(root, '..');

function fail(message) {
  console.error(`Batch D structural check failed: ${message}`);
  process.exitCode = 1;
}

function sourceFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? sourceFiles(path) : entry.name.endsWith('.ts') ? [path] : [];
  });
}

const runtimeSource = sourceFiles(join(root, 'src'))
  .map((path) => readFileSync(path, 'utf8'))
  .join('\n');
const importRoute = readFileSync(join(root, 'src/routes/playlist-import.ts'), 'utf8');
const wrangler = readFileSync(join(root, 'wrangler.toml'), 'utf8');
const project = readFileSync(join(repo, 'ios/Runner.xcodeproj/project.pbxproj'), 'utf8');

if (/\b(?:CREATE|ALTER|DROP)\s+(?:TABLE|INDEX)\b/i.test(runtimeSource)) {
  fail('workers/src still contains request-time DDL');
}
if (!importRoute.includes('const allResults = await Promise.all(')) {
  fail('anonymous preview fan-out changed');
}
if (!importRoute.includes('No hard cap on playlist size.')) {
  fail('unbounded Phase 2 song behavior changed');
}
if (/MAX_(?:BODY|SONGS|PLAYLIST)|songs\.length\s*>|content-length/i.test(importRoute)) {
  fail('an excluded playlist-import bound was introduced');
}
if (!wrangler.includes('compatibility_date = "2026-07-29"')) {
  fail('compatibility date is not 2026-07-29');
}
if (!wrangler.includes('[observability.logs]') || !wrangler.includes('[observability.traces]')) {
  fail('sampled logs and traces are not configured');
}
const privacyMentions = project.match(/PrivacyInfo\.xcprivacy/g)?.length ?? 0;
if (privacyMentions !== 3 || !project.includes('PrivacyInfo.xcprivacy in Resources')) {
  fail('PrivacyInfo.xcprivacy is not referenced once in file, group, and Runner resources');
}
if (/console\.(?:log|error|warn)\([^\n]*(?:Authorization|ADMIN_PASSWORD|TINYAPI_KEY|password|token)/i.test(runtimeSource)) {
  fail('runtime logging may include credentials');
}

if (!process.exitCode) console.log('Batch D structural checks passed.');
