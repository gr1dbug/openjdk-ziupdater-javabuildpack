# Update timezone data in an offline Java buildpack

Use [update_timezone.sh](update_timezone.sh) to build a custom Cloud Foundry Java buildpack with a newer IANA timezone database, keeping the bundled Java versions. 

You can update one JRE at a time or every pinned JRE with `--all`. Choose an output directory once: the combined result is always `<output-directory>/buildpack`. Each subsequent run starts from that result and preserves previously patched versions. There is no manual cache merging or changing `TZ_SOURCE` between runs.

## 1. Check prerequisites and inputs

Use a Linux host or container capable of running the exact runtimes bundled in the buildpack, with matching architecture and compatible libc. The updater runs with each extracted target JRE; it does not modify system Java or assume that a timezone database generated with one Java major version works with another.

Required commands are Bash, Ruby with its standard YAML/JSON/Digest libraries, Python 3.12 or later, GNU/Linux `flock`, `tar`, `cp`, `mktemp`, and `javac`. The compiler can be from JDK 8 or a newer JDK that supports `--release 8`. No additional Python or Ruby packages are required. The `cf` CLI is needed only for deployment.

This process supports Java 8 and later runtimes with a `tzdb.dat` file. Java 7's `lib/zi` layout requires a different procedure. Other runtimes and future tzdata releases must pass the updater and validation checks. See [Azul's ZIUpdater documentation](https://www.azul.com/products/components/ziupdater-time-zone-tool/) for the tool's invocation and installed-file layout.

Start in a directory containing:

```text
update_timezone.sh
JAVA_BUILDPACK_TZDATA_UPGRADE.md
offline/
ziupdater-1.1.3.1.jar
tzdata2026e.tar.gz
```

`offline/` is the unpacked offline buildpack, including its `resources/cache` directory. The script requires remote downloads to be disabled. Modifying an online buildpack would also require hosting the modified runtime artifacts; that is outside this procedure.

Inspect the inputs:

```bash
chmod +x update_timezone.sh
./update_timezone.sh --help
cat offline/config/open_jdk_jre.yml
cat offline/config/repository.yml
tar -xOf tzdata2026e.tar.gz version
tar -xOf tzdata2026e.tar.gz NEWS | head -n 65
```

Use a trusted updater and the intended IANA release archive. The script records their SHA-256 hashes whenever it installs a patch.

## 2. Select the output directory and runtime versions

The examples use `upd/` as the persistent output directory. It must be separate from the source buildpack, without either directory containing the other. Relative paths, absolute paths, spaces, and trailing slashes are supported. Pass a work directory such as `upd/`, not `upd/buildpack` as the second argument to the script.

List the exact pinned version keys:

```bash
ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jre").fetch("version_lines")' \
  offline/config/open_jdk_jre.yml
```

The tested bundle contains `1.8.0_504`, `11.0.32_11`, `17.0.20_10`, `21.0.12_10`, and `25.0.4_9`. Use your bundle's keys, including the build suffix: for example, `17.0.20_10`, rather than Java's printed `17.0.20+10`.

On the first run, the script copies `offline/` into a candidate buildpack. On later runs, it copies `upd/buildpack` into a fresh candidate. It replaces `upd/buildpack` only after the entire requested operation passes validation. The initial source and previous successful output are preserved.

## 3. Run one version, several successive versions, or all versions

For one version:

```bash
./update_timezone.sh 17.0.20_10 upd/
```

To add Java 11 to the same buildpack:

```bash
./update_timezone.sh 11.0.32_11 upd/
```

The result now includes both updates in `upd/buildpack`. Repeating either command validates the already-current JRE and skips repackaging it.

To process every entry in the current buildpack's `jre.version_lines`:

```bash
./update_timezone.sh --all upd/
```

`--all` works both with a new output directory and with a partially updated one. It skips JREs already on the requested tzdata release and updates the remaining versions. If any version fails, the prior `upd/buildpack` remains in place; partial changes from that invocation are kept only in its run directory for inspection.

The script retains the default Java version and `version_lines`. A single-version run changes only the selected JRE's timezone data. `--all` covers the JREs listed in `config/open_jdk_jre.yml`, not every dependency or alternative JVM implementation in the buildpack.

To start a separate build from the original source, choose a new output directory. Reusing `upd/` deliberately continues its existing buildpack even if you change `TZ_SOURCE`.

## 4. Adjust inputs for another buildpack or tzdata release

These defaults can be overridden with environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `TZ_SOURCE` | `$PWD/offline` | Initial source; later runs use the existing output buildpack |
| `TZ_UPDATER` | `$PWD/ziupdater-1.1.3.1.jar` | ZIUpdater JAR |
| `TZ_DATA` | `$PWD/tzdata2026e.tar.gz` | IANA source archive; release is read from its `version` member |
| `TZ_PLATFORMS` | `bionic jammy resolute` | All platform variants the output should support |
| `TZ_ARCH` | `x86_64` | Repository architecture key |
| `TZ_JAVAC` | `javac` | Compiler executable or path |

For example, if your unpacked buildpack supports only Jammy:

```bash
TZ_SOURCE="$PWD/my-offline-buildpack" \
TZ_UPDATER="$PWD/ziupdater-1.1.3.1.jar" \
TZ_DATA="$PWD/tzdata2026e.tar.gz" \
TZ_PLATFORMS="jammy" \
TZ_ARCH="x86_64" \
./update_timezone.sh --all my-output/
```

Use the same complete platform and architecture selection when continuing an output directory. The repository root is shared across JRE versions; omitting a platform means the new namespace will not support that platform. Missing selected index/version entries stop the run. Multi-architecture buildpacks require an adapted procedure; this script targets one architecture per combined output.

`TZ_WORK`, `TZ_BP`, `TZ_JRE_VERSION`, and `TZ_PATCH_ID` are managed internally. Set the version and output directory through the two command-line arguments. A fresh patch namespace is generated when a JRE changes, so an earlier staged application cache cannot select the old dependency through an unchanged URL.

## 5. Understand the cache and patching process

This Java buildpack uses a content-addressed cache:

```text
SHA256(exact URL).cached  ->  64 ASCII hex characters, with no newline
SHA256(payload).blob     ->  index YAML, JRE archive, or another dependency
```

A `.blob` filename therefore does not identify the Java version. The script handles both levels of indirection and keeps the updated repository indices together in the combined buildpack.

For each requested version, the script:

1. Resolves the currently configured repository index for every selected platform and verifies the cached archive's hash.
2. Extracts each distinct archive into an updater copy and a clean copy. Byte-identical archives shared by platforms are processed once for that version.
3. Runs the timezone probe with the exact extracted JRE. Already-current JREs are validated and skipped; a newer installed tzdata release is rejected rather than downgraded.
4. Runs that JRE's `bin/java -jar ziupdater.jar -l file:///absolute/path/to/tzdata.tar.gz -v` against the updater copy.
5. Copies only the resulting `tzdb.dat` into the clean copy, preserving its permissions, and validates it.
6. Repackages the original archive layout and metadata. It verifies that `tzdb.dat` is the only changed member, then extracts and tests the repackaged archive.
7. Writes the new blobs, URL pointers, and repository indices. Other Java versions retain their existing URLs and artifacts. Obsolete pointers are redirected consistently; only superseded JRE blobs with no references are removed.
8. Records provenance, verifies all cache hashes and pointers plus prior recorded patches through the current indices, and checks unchanged Java defaults, offline mode, and executable entrypoints.
9. Promotes the validated candidate to the fixed output path. When updating an existing output, the previous buildpack is moved into that invocation's run directory.

The new `https://offline.invalid/...` URLs are cache identities, not a repository you need to host. Downloads remain disabled. Both index and modified-artifact identities change to avoid stale application cache entries.

## 6. Inspect the results and logs

A successful command prints the upload path, each selected version's `updated` or `already_current` status, and the run directory. The layout is:

```text
upd/
  buildpack/                         # Upload this directory
    resources/timezone-updates.json  # Accumulated patches installed by this script
  runs/
    run.<unique-id>/
      results.json                   # Results for all versions requested in this invocation
      baseline-jre.yml
      jre-<version>.<unique-id>/
        inputs.json
        result.json
        originals/
        probe/TzSmoke.java
        probe/TzSmoke.class
        cases/<original-archive-sha>/
          before.log
          version.log
          after.log
          layout.json
          ziupdater.log              # Present when the updater was needed
          repacked.log              # Present when repackaging was needed
      previous-buildpack/            # Present when an existing result was replaced
```

The accumulator records versions changed by this script. A JRE already patched before using this script may appear only as `already_current` in that invocation's `results.json`. Older patch reports are retained as historical records.

Inspect the accumulated metadata when present:

```bash
python3 -m json.tool upd/buildpack/resources/timezone-updates.json
```

Use the printed run directory for the authoritative results of that invocation:

```bash
# Replace the path with the one printed by your run.
python3 -m json.tool upd/runs/run.XXXXXXXX/results.json
```

Validation loads all available Java zones at sample dates and compares modern `java.time` with legacy `java.util.TimeZone` for the selected Canadian zones and aliases. For `2026e`, the embedded `TzSmoke` program also asserts the expected offsets at November 2026, January 2027, and July 2027 dates, with neighboring zones as controls. For another release or timezone change, adjust the expected-offset assertions in the script's `TzSmoke` program; version and loading checks alone do not establish that every business rule is correct.

The local regression checks for this script cover successive Java 17 and Java 11 updates, repeat runs, all five pinned JRE versions, legacy directory recovery, and failure preservation after a partial update. The actual buildpack resolver also selects all five patched versions across all three platforms with a stale application cache. Foundation staging and application behavior still need testing on the intended stack.

## 7. Resume after a failure or an older script run

Rerun the same command with the same output directory. Each invocation uses a new directory under `runs/` A lock prevents two updater processes from using the same output directory concurrently.

A failed run prints its run directory. Inspect the named updater or probe log, correct the cause, and rerun. In particular, every extracted JRE must be executable on the work host and accepted by the supplied updater. To retry a failed `--all` as smaller steps, run individual versions against the same output directory.

Run directories retain complete previous buildpacks, extracted JREs, archives, and logs; allow several GB of free space and expect repeated runs to add more. After retaining the evidence and rollback copies you need, old run directories may be removed while no updater is running. The completed `buildpack/` is self-contained and does not depend on `runs/`. Upload only `upd/buildpack`, not the outer `upd/` directory.

## 8. Upload the combined buildpack

The [cf CLI accepts a local directory](https://docs.cloudfoundry.org/adminguide/buildpacks.html), so a separate ZIP is unnecessary. The updater does not run any Cloud Foundry commands.

Run the deployment yourself against the intended foundation:

```bash
TZ_BUILDPACK_NAME="java-buildpack-canada-datefix"
TZ_BP="$PWD/upd/buildpack"
cf target
cf create-buildpack "$TZ_BUILDPACK_NAME" "$TZ_BP" 1
cf buildpacks
```

The last argument sets buildpack detection priority; choose the position appropriate for your foundation. To deliberately replace an existing custom buildpack of the same name:

```bash
cf update-buildpack "$TZ_BUILDPACK_NAME" -p "$TZ_BP"
```

## 9. Select the patched runtime and stage a canary

Installing a buildpack does not update existing droplets. Explicitly select the custom buildpack and the intended Java version. Merge a fragment like this into the appropriate application entry in the canary's existing manifest:

```yaml
buildpacks:
  - java-buildpack-canada-datefix
env:
  JBP_CONFIG_OPEN_JDK_JRE: '{ jre: { version: "17.0.20_10" } }'
```

Preserve other settings in an existing `JBP_CONFIG_OPEN_JDK_JRE`. Remove or align an application/operator override of `jre.repository_root`, if any exists because pointing back to the original repository bypasses the patched indices.

Push the canary with its updated manifest, or restage an existing app after selecting the custom buildpack. A restart reuses the existing droplet; see [Cloud Foundry's restart and restage documentation](https://docs.cloudfoundry.org/devguide/deploy-apps/start-restart-restage.html).

Validate the running application's JVM, not the workstation JVM. Log or inspect:

```java
System.getProperty("java.runtime.version")
java.time.zone.ZoneRulesProvider.getVersions("America/Winnipeg").keySet()
java.time.Instant.parse("2026-11-01T12:00:00Z")
    .atZone(java.time.ZoneId.of("America/Winnipeg"))
```

For this example, expect the intended Java version, `[2026e]`, and Winnipeg at `2026-11-01T07:00-05:00`. Check affected zones and aliases, both sides of cancelled transitions, future winter/summer dates, and the application's schedules and date formatting. The generated `TzSmoke.class` can also be included in a canary payload and executed with its staged JRE. Repeat canary staging for each Java version your applications use.

Updating `tzdb.dat` updates Java's timezone rules. It does not update OS/native timezone data, database servers, libraries carrying their own timezone database, or CLDR/localized timezone display names. Test those separately when relevant to the application.

## 10. Preserve provenance and rollback

Keep the original source buildpack, input archives, updater version/hash, accumulated patch metadata, and validation logs. Each replacement of an existing output also keeps the previous buildpack at the printed `runs/run.<id>/previous-buildpack` path.

To undo a foundation-side custom buildpack replacement, select the original registered buildpack for the application, or deliberately upload the preserved source under the custom name:

```bash
cf update-buildpack "$TZ_BUILDPACK_NAME" -p "$PWD/offline"
```

Use the corresponding `previous-buildpack` path instead if you need the immediately preceding custom revision. Restage affected canaries and verify the runtime data version; restoring a buildpack alone does not replace existing droplets. When an appropriate vendor build becomes available, return to that maintained runtime through the normal buildpack update and staging process.
