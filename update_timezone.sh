#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./update_timezone.sh VERSION OUTPUT_DIR
       ./update_timezone.sh --all OUTPUT_DIR

Example: ./update_timezone.sh 17.0.20_10 upd/
         ./update_timezone.sh 11.0.32_11 upd/
         ./update_timezone.sh --all upd/

The combined, validated buildpack is always OUTPUT_DIR/buildpack.
Later runs start from that buildpack. Each invocation gets a fresh runs/ directory.
Already-current JREs are validated and skipped. No Cloud Foundry commands are run.

Environment overrides (paths may be relative to the current directory):
  TZ_SOURCE     Initial source buildpack (default: ./offline; used only to initialize)
  TZ_UPDATER    ZIUpdater JAR (default: ./ziupdater-1.1.3.1.jar)
  TZ_DATA       IANA archive (default: ./tzdata2026e.tar.gz)
  TZ_PLATFORMS  All supported platforms (default: bionic jammy resolute)
  TZ_ARCH       Architecture (default: x86_64)
  TZ_JAVAC      Java compiler executable (default: javac)
USAGE
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
if [[ $# != 2 || -z $1 || -z $2 ]]; then usage >&2; exit 2; fi
requested_version=$1
export TZ_ROOT="$PWD"
export TZ_SOURCE="${TZ_SOURCE:-$TZ_ROOT/offline}"
export TZ_UPDATER="${TZ_UPDATER:-$TZ_ROOT/ziupdater-1.1.3.1.jar}"
export TZ_DATA="${TZ_DATA:-$TZ_ROOT/tzdata2026e.tar.gz}"
export TZ_PLATFORMS="${TZ_PLATFORMS:-bionic jammy resolute}"
export TZ_ARCH="${TZ_ARCH:-x86_64}"
export TZ_JAVAC="${TZ_JAVAC:-javac}"
export TZ_OUTPUT="$2"
python3 -c 'import sys; assert sys.version_info >= (3, 12), "Python 3.12+ is required"'
ruby -ryaml -rjson -rdigest -e 'puts "Ruby prerequisites OK"'
command -v flock >/dev/null
command -v "$TZ_JAVAC" >/dev/null
# Canonical paths also make Java's classpath independent of the output argument's spelling.
for path_var in TZ_SOURCE TZ_UPDATER TZ_DATA TZ_OUTPUT; do
  resolved_path="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "${!path_var}")"
  printf -v "$path_var" '%s' "$resolved_path"
  export "$path_var"
done
test -f "$TZ_UPDATER"
test -f "$TZ_DATA"
python3 - <<'PY'
import os, pathlib
source = pathlib.Path(os.environ['TZ_SOURCE'])
output = pathlib.Path(os.environ['TZ_OUTPUT'])
if output == source or output.is_relative_to(source) or source.is_relative_to(output):
    raise SystemExit('Source and output directories must be separate, without nesting.')
if (output / 'config/open_jdk_jre.yml').exists():
    raise SystemExit('OUTPUT_DIR must be a work directory, not an unpacked buildpack itself.')
PY
mkdir -p "$TZ_OUTPUT/runs"
exec 9>"$TZ_OUTPUT/.timezone-update.lock"
flock -n 9 || { printf 'Another update is using %s\n' "$TZ_OUTPUT" >&2; exit 1; }
TZ_RELEASE="$(tar -xOf "$TZ_DATA" version)"
export TZ_RELEASE
[[ $TZ_RELEASE =~ ^[0-9]{4}[a-z]+$ ]] || { printf 'Invalid tzdata release: %s\n' "$TZ_RELEASE" >&2; exit 1; }
TZ_RUN="$(mktemp -d "$TZ_OUTPUT/runs/run.XXXXXXXX")"
export TZ_RUN
export TZ_BP="$TZ_RUN/candidate-buildpack"
trap 'rc=$?; if (( rc != 0 )); then printf "Update failed; the previous output buildpack was not replaced. Inspect %s\n" "$TZ_RUN" >&2; fi' EXIT

# Adopt an existing result, including the legacy script's nested-only copy layout.
export TZ_BASELINE="$TZ_SOURCE"
if [[ -d $TZ_OUTPUT/buildpack ]]; then
  if [[ -f $TZ_OUTPUT/buildpack/config/open_jdk_jre.yml ]]; then
    TZ_BASELINE="$TZ_OUTPUT/buildpack"
  elif [[ -f $TZ_OUTPUT/buildpack/offline/config/open_jdk_jre.yml ]]; then
    TZ_BASELINE="$TZ_OUTPUT/buildpack/offline"
    printf 'Recovering the legacy nested buildpack layout.\n'
  else
    printf 'Existing output/buildpack is not a recognizable Java buildpack; leaving it untouched.\n' >&2
    exit 1
  fi
fi
test -f "$TZ_BASELINE/config/open_jdk_jre.yml"
test -d "$TZ_BASELINE/resources/cache"
if [[ $requested_version == --all ]]; then
  versions_text="$(ruby -ryaml -e 'v=YAML.load_file(ARGV[0]).fetch("jre").fetch("version_lines"); abort "Empty version_lines" if v.empty?; puts v.uniq' "$TZ_BASELINE/config/open_jdk_jre.yml")"
  mapfile -t versions <<< "$versions_text"
else
  versions=("$requested_version")
fi
for version in "${versions[@]}"; do
  [[ $version =~ ^[0-9][A-Za-z0-9._-]*$ ]] || { printf 'An exact pinned JRE version is required: %s\n' "$version" >&2; exit 2; }
done
mkdir -p "$TZ_BP"
cp -a "$TZ_BASELINE/." "$TZ_BP/"
cp -a "$TZ_BP/config/open_jdk_jre.yml" "$TZ_RUN/baseline-jre.yml"
# The old `mkdir buildpack; cp -a offline buildpack` can leave an extra full buildpack.
# Preserve that copy outside the new upload tree rather than deleting it.
python3 - <<'PY'
import os, pathlib, shutil
run = pathlib.Path(os.environ['TZ_RUN'])
bp = pathlib.Path(os.environ['TZ_BP'])
for name in {'offline', pathlib.Path(os.environ['TZ_SOURCE']).name}:
    nested = bp / name
    if (nested / 'config/open_jdk_jre.yml').is_file() and (nested / 'resources/cache').is_dir():
        destination = run / ('legacy-nested-' + name)
        shutil.move(str(nested), str(destination))
        print('Preserved accidental nested buildpack outside upload tree:', destination)
PY
printf 'Output buildpack: %s/buildpack\nRun directory: %s\nTarget tzdata: %s\n' "$TZ_OUTPUT" "$TZ_RUN" "$TZ_RELEASE"

for version in "${versions[@]}"; do
export TZ_JRE_VERSION="$version"
export TZ_PATCH_ID="tzdata${TZ_RELEASE}-jre${version}-${TZ_RUN##*/}"
TZ_WORK="$(mktemp -d "$TZ_RUN/jre-${version}.XXXXXX")"
export TZ_WORK
printf '\nChecking JRE %s\n' "$version"


cat > "$TZ_WORK/cache_helpers.rb" <<'RUBY'
require 'yaml'
require 'json'
require 'digest'
require 'fileutils'

WORK = ENV.fetch('TZ_WORK')
BP = ENV.fetch('TZ_BP')
CACHE = File.join(BP, 'resources/cache')
JRE_VERSION = ENV.fetch('TZ_JRE_VERSION')

def cache_path(uri)
  key = Digest::SHA256.hexdigest(uri)
  pointer = File.join(CACHE, "#{key}.cached")
  sha = File.binread(pointer)
  abort "Unsupported cache pointer format: #{pointer}" unless /\A[0-9a-f]{64}\z/.match?(sha)
  blob = File.join(CACHE, "#{sha}.blob")
  abort "Cache content hash mismatch: #{blob}" unless Digest::SHA256.file(blob).hexdigest == sha
  blob
end

def put_cache(uri, bytes)
  key = Digest::SHA256.hexdigest(uri)
  sha = Digest::SHA256.hexdigest(bytes)
  File.binwrite(File.join(CACHE, "#{sha}.blob"), bytes)
  File.binwrite(File.join(CACHE, "#{key}.cached"), sha) # No newline.
  %w[etag last_modified].each { |ext| FileUtils.rm_f(File.join(CACHE, "#{key}.#{ext}")) }
  sha
end
RUBY

ruby -I"$TZ_WORK" -rcache_helpers <<'RUBY'
config = YAML.load_file(File.join(BP, 'config/open_jdk_jre.yml'))
repo = YAML.load_file(File.join(BP, 'config/repository.yml'))
cache_config = YAML.load_file(File.join(BP, 'config/cache.yml'))
abort 'Start with an offline buildpack' unless cache_config['remote_downloads'] == 'disabled'
abort 'Choose a version in version_lines' unless config.fetch('jre').fetch('version_lines').include?(JRE_VERSION)
template = config.fetch('jre').fetch('repository_root')
FileUtils.mkdir_p(File.join(WORK, 'originals'))

records = ENV.fetch('TZ_PLATFORMS').split.map do |platform|
  root = template.gsub('{default.repository.root}', repo.fetch('default_repository_root').sub(%r{/$}, ''))
                 .gsub('{platform}', platform).gsub('{architecture}', ENV.fetch('TZ_ARCH')).sub(%r{/$}, '')
  abort "Unresolved repository placeholder: #{root}" if root.include?('{')
  index_uri = "#{root}/index.yml"
  index = YAML.safe_load(File.read(cache_path(index_uri)))
  uri = index.fetch(JRE_VERSION)
  archive = cache_path(uri)
  sha = Digest::SHA256.file(archive).hexdigest
  original = File.join(WORK, 'originals', "#{sha}.tar.gz")
  FileUtils.cp(archive, original) unless File.exist?(original)
  puts "#{platform}/#{ENV.fetch('TZ_ARCH')}: #{JRE_VERSION}\n  #{uri}\n  #{sha}"
  { 'platform' => platform, 'architecture' => ENV.fetch('TZ_ARCH'), 'index_uri' => index_uri,
    'original_uri' => uri, 'original_sha' => sha }
end
File.write(File.join(WORK, 'inputs.json'), JSON.pretty_generate(records) + "\n")
RUBY


mkdir -p "$TZ_WORK/probe"
cat > "$TZ_WORK/probe/TzSmoke.java" <<'JAVA'
import java.time.*;
import java.time.zone.ZoneRulesProvider;
import java.util.TimeZone;

public class TzSmoke {
    public static void main(String[] args) {
        String version = ZoneRulesProvider.getVersions("America/Winnipeg").lastKey();
        if (args.length > 0 && args[0].equals("--version")) {
            System.out.println("TZDATA_VERSION=" + version);
            return;
        }
        System.out.println("Java=" + System.getProperty("java.runtime.version") + " tzdata=" + version);
        if (args.length > 0 && !version.equals(args[0])) throw new AssertionError("Unexpected tzdata");
        String[] dates = {"2026-11-01T12:00:00Z", "2027-01-15T12:00:00Z", "2027-07-15T12:00:00Z"};
        for (String id : ZoneId.getAvailableZoneIds()) {
            for (String date : dates) ZoneId.of(id).getRules().getOffset(Instant.parse(date));
        }
        String[][] cases = {
            {"America/Vancouver", "-07:00", "-07:00"}, {"Canada/Pacific", "-07:00", "-07:00"},
            {"America/Edmonton", "-06:00", "-06:00"}, {"Canada/Mountain", "-06:00", "-06:00"},
            {"America/Inuvik", "-06:00", "-06:00"}, {"America/Yellowknife", "-06:00", "-06:00"},
            {"America/Winnipeg", "-05:00", "-05:00"}, {"Canada/Central", "-05:00", "-05:00"},
            {"America/Regina", "-06:00", "-06:00"}, {"America/Los_Angeles", "-08:00", "-07:00"},
            {"America/Denver", "-07:00", "-06:00"}, {"America/Toronto", "-05:00", "-04:00"}
        };
        for (String[] c : cases) {
            for (int i = 0; i < dates.length; i++) {
                Instant instant = Instant.parse(dates[i]);
                ZoneOffset offset = ZoneId.of(c[0]).getRules().getOffset(instant);
                TimeZone legacy = TimeZone.getTimeZone(c[0]);
                if (!legacy.getID().equals(c[0]) || legacy.getOffset(instant.toEpochMilli()) / 1000 != offset.getTotalSeconds())
                    throw new AssertionError("API mismatch: " + c[0]);
                if (args.length > 0 && args[0].equals("2026e") && !offset.equals(ZoneOffset.of(c[i == 2 ? 2 : 1])))
                    throw new AssertionError("Wrong offset: " + c[0] + " " + instant + " " + offset);
                System.out.println(c[0] + " " + instant + " " + offset);
            }
        }
        System.out.println("PASS zones=" + ZoneId.getAvailableZoneIds().size());
    }
}
JAVA

if [[ $("$TZ_JAVAC" -version 2>&1) == 'javac 1.8.'* ]]; then
  "$TZ_JAVAC" -source 8 -target 8 -d "$TZ_WORK/probe" "$TZ_WORK/probe/TzSmoke.java"
else
  "$TZ_JAVAC" --release 8 -Xlint:-options -d "$TZ_WORK/probe" "$TZ_WORK/probe/TzSmoke.java"
fi



python3 - <<'PY'
import json, os, pathlib, re, shutil, subprocess, tarfile
w = pathlib.Path(os.environ['TZ_WORK'])
inputs = json.loads((w / 'inputs.json').read_text())
updater = pathlib.Path(os.environ['TZ_UPDATER']).resolve()
data_uri = pathlib.Path(os.environ['TZ_DATA']).resolve().as_uri()

for sha in sorted({r['original_sha'] for r in inputs}):
    case = w / 'cases' / sha
    case.mkdir(parents=True) # Each invocation/version now has a fresh workspace.
    for name in ['updater', 'clean']:
        target = case / name
        target.mkdir()
        with tarfile.open(w / 'originals' / (sha + '.tar.gz'), 'r:gz') as archive:
            archive.extractall(target, filter='data')
    launchers = sorted((p for p in (case / 'updater').rglob('bin/java') if p.is_file()),
                       key=lambda p: (len(p.parts), str(p)))
    assert launchers, 'No bin/java in archive'
    java = launchers[0] # Prefer the outer JDK launcher if Java 8 also has jre/bin/java.
    java_rel = java.relative_to(case / 'updater')
    clean_java = case / 'clean' / java_rel
    def run(command, log):
        with (case / log).open('w') as output:
            result = subprocess.run([str(x) for x in command], stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError('Command failed; inspect ' + str(case / log))
    run([clean_java, '-cp', w / 'probe', 'TzSmoke'], 'before.log')
    run([clean_java, '-cp', w / 'probe', 'TzSmoke', '--version'], 'version.log')
    current = re.search(r'^TZDATA_VERSION=(\S+)$', (case / 'version.log').read_text(), re.M).group(1)
    target_version = os.environ['TZ_RELEASE']
    databases = list((case / 'clean').rglob('tzdb.dat'))
    assert len(databases) == 1, 'Expected exactly one tzdb.dat; inspect this runtime layout'
    tz_rel = databases[0].relative_to(case / 'clean')
    if current == target_version:
        run([clean_java, '-cp', w / 'probe', 'TzSmoke', target_version], 'after.log')
        (case / 'layout.json').write_text(json.dumps({'java': str(java_rel), 'tzdb': str(tz_rel),
            'changed': False, 'before_tzdata': current, 'after_tzdata': current}, indent=2))
        print('Already at tzdata' + current + '; validated without repackaging:', sha)
        continue
    if re.fullmatch(r'[0-9]{4}[a-z]+', current) and current > target_version:
        raise RuntimeError('Refusing to downgrade tzdata' + current + ' to ' + target_version)
    run([java, '-jar', updater, '-V'], 'updater-before.log')
    run([java, '-jar', updater, '-l', data_uri, '-v'], 'ziupdater.log')
    updated_db = case / 'updater' / tz_rel
    clean_db = case / 'clean' / tz_rel
    assert updated_db.read_bytes() != clean_db.read_bytes(), 'Updater produced no timezone change'
    shutil.copyfile(updated_db, clean_db) # Preserve the clean file's permissions.
    run([clean_java, '-cp', w / 'probe', 'TzSmoke', os.environ['TZ_RELEASE']], 'after.log')
    (case / 'layout.json').write_text(json.dumps({'java': str(java_rel), 'tzdb': str(tz_rel),
        'changed': True, 'before_tzdata': current, 'after_tzdata': target_version}, indent=2))
    print('Updated and validated:', sha, 'database:', tz_rel)
    print((case / 'after.log').read_text().splitlines()[-1])
PY


python3 - <<'PY'
import copy, gzip, hashlib, io, json, os, pathlib, shutil, subprocess, tarfile
w = pathlib.Path(os.environ['TZ_WORK'])
for case in sorted((w / 'cases').iterdir()):
    layout = json.loads((case / 'layout.json').read_text())
    tz_rel = layout['tzdb']
    replacement = (case / 'clean' / tz_rel).read_bytes()
    original = w / 'originals' / (case.name + '.tar.gz')
    packed = case / 'patched.tar.gz'
    if not layout['changed']:
        shutil.copyfile(original, packed)
        continue
    replaced = 0
    with tarfile.open(original, 'r:gz') as src, packed.open('wb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode='w') as dst:
                for member in src:
                    updated = copy.copy(member)
                    if pathlib.PurePosixPath(member.name).as_posix() == tz_rel:
                        assert member.isfile(), 'Expected a regular timezone data file'
                        updated.size = len(replacement)
                        dst.addfile(updated, io.BytesIO(replacement))
                        replaced += 1
                    else:
                        dst.addfile(updated, src.extractfile(member) if member.isfile() else None)
    assert replaced == 1
    with tarfile.open(original) as src, tarfile.open(packed) as dst:
        left, right = src.getmembers(), dst.getmembers()
        assert [m.name for m in left] == [m.name for m in right]
        changed = []
        for a, b in zip(left, right):
            for field in ['mode', 'uid', 'gid', 'uname', 'gname', 'mtime', 'type', 'linkname']:
                assert getattr(a, field) == getattr(b, field), (a.name, field)
            if a.isfile() and src.extractfile(a).read() != dst.extractfile(b).read():
                changed.append(pathlib.PurePosixPath(a.name).as_posix())
        assert changed == [tz_rel], changed
        verify_dir = case / 'repacked'
        verify_dir.mkdir()
        dst.extractall(verify_dir, filter='data')
    with (case / 'repacked.log').open('w') as log:
        subprocess.run([str(verify_dir / layout['java']), '-cp', str(w / 'probe'),
                        'TzSmoke', os.environ['TZ_RELEASE']], check=True, stdout=log, stderr=subprocess.STDOUT)
    with packed.open('rb') as f:
        sha = hashlib.file_digest(f, 'sha256').hexdigest()
    print('Verified', packed, 'SHA256', sha, 'only changed member:', tz_rel)
PY


ruby -I"$TZ_WORK" -rcache_helpers <<'RUBY'
require 'uri'
records = JSON.parse(File.read(File.join(WORK, 'inputs.json')))
patch_id = ENV.fetch('TZ_PATCH_ID')
layouts = records.to_h do |r|
  [r.fetch('original_sha'), JSON.parse(File.read(File.join(WORK, 'cases', r.fetch('original_sha'), 'layout.json')))]
end
changed = layouts.values.any? { |layout| layout.fetch('changed') }
if !changed
  records.each { |r| r.merge!('patched_uri' => r.fetch('original_uri'), 'patched_sha' => r.fetch('original_sha')) }
  result = { 'java_version_key' => JRE_VERSION, 'tzdata_version' => ENV.fetch('TZ_RELEASE'),
             'status' => 'already_current', 'cache_entries' => records }
  File.write(File.join(WORK, 'result.json'), JSON.pretty_generate(result) + "\n")
  puts "JRE #{JRE_VERSION}: already current; existing cache/configuration retained."
  exit
end

new_root = "https://offline.invalid/#{patch_id}/openjdk"
new_hashes = {}
records.each do |r|
  archive = File.join(WORK, 'cases', r.fetch('original_sha'), 'patched.tar.gz')
  new_hashes[r.fetch('original_sha')] = Digest::SHA256.file(archive).hexdigest
end
# Snapshot old pointers before creating any new ones; do not remap newly written pointers.
old_pointers = Dir.glob(File.join(CACHE, '*.cached')).to_h { |p| [p, File.binread(p)] }

records.each do |r|
  platform = r.fetch('platform')
  archive = File.join(WORK, 'cases', r.fetch('original_sha'), 'patched.tar.gz')
  bytes = File.binread(archive)
  # Retain a recognizable filename, but use an entirely new cache URI.
  filename = File.basename(URI.parse(r.fetch('original_uri')).path)
  new_uri = "#{new_root}/#{platform}/#{ENV.fetch('TZ_ARCH')}/#{filename}"
  put_cache(new_uri, bytes)
  index = YAML.safe_load(File.read(cache_path(r.fetch('index_uri'))))
  index[JRE_VERSION] = new_uri
  new_index_uri = "#{new_root}/#{platform}/#{ENV.fetch('TZ_ARCH')}/index.yml"
  index_sha = put_cache(new_index_uri, YAML.dump(index))
  r.merge!('patched_uri' => new_uri, 'patched_sha' => new_hashes[r.fetch('original_sha')],
           'patched_index_uri' => new_index_uri, 'patched_index_sha' => index_sha)
end

# Keep original JRE URLs usable from the embedded cache, too. Remove stale HTTP validators.
old_pointers.each do |pointer, old_sha|
  next unless new_hashes.key?(old_sha)
  File.binwrite(pointer, new_hashes.fetch(old_sha))
  key = File.basename(pointer, '.cached')
  %w[etag last_modified].each { |ext| FileUtils.rm_f(File.join(CACHE, "#{key}.#{ext}")) }
end
new_hashes.each_key do |old_sha|
  referenced = Dir.glob(File.join(CACHE, '*.cached')).any? { |p| File.binread(p) == old_sha }
  FileUtils.rm_f(File.join(CACHE, "#{old_sha}.blob")) unless referenced
end

path = File.join(BP, 'config/open_jdk_jre.yml')
config = YAML.load_file(path)
config.fetch('jre')['repository_root'] = "#{new_root}/{platform}/{architecture}"
File.write(path, YAML.dump(config)) # Normalizes YAML formatting; defaults/version_lines stay intact.
path = File.join(BP, 'config/version.yml')
version = YAML.load_file(path)
state_path = File.join(BP, 'resources/timezone-updates.json')
state = if File.exist?(state_path)
          JSON.parse(File.read(state_path))
        else
          { 'base_buildpack_version' => version.fetch('version'), 'versions' => {} }
        end
version['version'] = "#{state.fetch('base_buildpack_version')}-tzdata#{ENV.fetch('TZ_RELEASE')}"
version['offline'] = true
File.write(path, YAML.dump(version))
report = { 'patch_id' => patch_id, 'java_version_key' => JRE_VERSION,
           'status' => 'updated',
           'tzdata_version' => ENV.fetch('TZ_RELEASE'), 'buildpack_version' => version['version'],
           'tzdata_sha256' => Digest::SHA256.file(ENV.fetch('TZ_DATA')).hexdigest,
           'ziupdater_sha256' => Digest::SHA256.file(ENV.fetch('TZ_UPDATER')).hexdigest,
           'cache_entries' => records }
state.fetch('versions')[JRE_VERSION] = report
File.write(state_path, JSON.pretty_generate(state) + "\n")
File.write(File.join(WORK, 'result.json'), JSON.pretty_generate(report) + "\n")
puts "Installed #{JRE_VERSION} with tzdata#{ENV.fetch('TZ_RELEASE')} into candidate buildpack."
RUBY
done

# Validate all versions processed in this invocation AND previously recorded patches
# through the currently configured indices, not historical snapshot indices.
ruby -I"$TZ_WORK" -rcache_helpers <<'RUBY'
Dir.glob(File.join(CACHE, '*.blob')).each do |blob|
  abort "Bad blob hash: #{blob}" unless Digest::SHA256.file(blob).hexdigest == File.basename(blob, '.blob')
end
Dir.glob(File.join(CACHE, '*.cached')).each do |pointer|
  sha = File.binread(pointer)
  abort "Bad pointer: #{pointer}" unless /\A[0-9a-f]{64}\z/.match?(sha)
  abort "Missing payload: #{pointer}" unless File.file?(File.join(CACHE, "#{sha}.blob"))
end
config = YAML.load_file(File.join(BP, 'config/open_jdk_jre.yml'))
source_config = YAML.load_file(File.join(ENV.fetch('TZ_RUN'), 'baseline-jre.yml'))
%w[version version_lines].each do |key|
  abort "Changed JRE #{key}" unless config.fetch('jre')[key] == source_config.fetch('jre')[key]
end
results = Dir.glob(File.join(ENV.fetch('TZ_RUN'), 'jre-*/result.json')).sort.map { |p| JSON.parse(File.read(p)) }
state_path = File.join(BP, 'resources/timezone-updates.json')
previous = File.exist?(state_path) ? JSON.parse(File.read(state_path)).fetch('versions').values : []
reports = (previous + results).to_h { |r| [r.fetch('java_version_key'), r] }.values
default_root = YAML.load_file(File.join(BP, 'config/repository.yml')).fetch('default_repository_root').sub(%r{/$}, '')
reports.each do |report|
  report.fetch('cache_entries').each do |r|
    root = config.fetch('jre').fetch('repository_root').gsub('{default.repository.root}', default_root)
                 .gsub('{platform}', r.fetch('platform')).gsub('{architecture}', r.fetch('architecture')).sub(%r{/$}, '')
    index = YAML.safe_load(File.read(cache_path("#{root}/index.yml")))
    uri = index.fetch(report.fetch('java_version_key'))
    abort 'Wrong JRE URL' unless uri == r.fetch('patched_uri')
    abort 'Wrong JRE bytes' unless Digest::SHA256.file(cache_path(uri)).hexdigest == r.fetch('patched_sha')
  end
end
abort 'Downloads enabled' unless YAML.load_file(File.join(BP, 'config/cache.yml'))['remote_downloads'] == 'disabled'
%w[detect compile release].each { |name| abort "Not executable: #{name}" unless File.executable?(File.join(BP, 'bin', name)) }
puts 'PASS: cache hashes, pointers, selected JRE indices, defaults, offline mode, executable scripts'
File.write(File.join(ENV.fetch('TZ_RUN'), 'results.json'), JSON.pretty_generate(results) + "\n")
RUBY

python3 - <<'PY'
import json, os, pathlib, shutil
run = pathlib.Path(os.environ['TZ_RUN'])
candidate = pathlib.Path(os.environ['TZ_BP'])
output = pathlib.Path(os.environ['TZ_OUTPUT']) / 'buildpack'
results = json.loads((run / 'results.json').read_text())
changed = any(r['status'] == 'updated' for r in results)
repaired_layout = any(run.glob('legacy-nested-*')) or pathlib.Path(os.environ['TZ_BASELINE']) == output / 'offline'
if output.exists() and not changed and not repaired_layout:
    shutil.rmtree(candidate) # Only this run's disposable copy.
    print('All selected JREs already current; output buildpack left unchanged.')
else:
    previous = run / 'previous-buildpack'
    if output.exists():
        output.rename(previous)
    try:
        candidate.rename(output)
    except BaseException:
        if previous.exists() and not output.exists():
            previous.rename(output)
        raise
    if previous.exists():
        print('Previous output preserved:', previous)
for r in results:
    print(r['java_version_key'] + ': ' + r['status'] + ' (tzdata' + r['tzdata_version'] + ')')
print('Ready to upload:', output)
print('Logs and per-JRE results:', run)
PY
