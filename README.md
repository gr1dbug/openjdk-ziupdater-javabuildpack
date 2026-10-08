## overview
updates a java buildpack with a given tzdata release from IANA.

## prereqs
- linux, x86_64
- python >= 3.12
- ruby (any recent version)
- java 8+ jdk
- ziupdater tool - download [here](https://www.azul.com/products/components/ziupdater-time-zone-tool/)
- tzdata2026e.tar.gz (download from IANA)

## quickstart
create a working directory. inside it, make a directory named "offline" and another called "updated" (the modified buildpack will be output in the latter directory, you can specify any path you like; the source directory must be called "offline").

inside "offline" unzip the java-buildpack-offline-v\<version\>.zip.

in the root of the working directory, unpack ziupdater. copy the tzdata2026e.tar.gz file in to the root as well; don't unpack it.

copy the update_timezone.sh script from this repo into the root of your working directory.

run "./update_timezone.sh --all updated/" (replace "updated/" with the path of your choice)

once complete, the modified buildpack will be at \<outputdir\>/buildpack. a run log will be available at \<outputdir\>/runs/\<run-id\>/results.json. verify that it shows success. also verify timestamps on the files in \<outputdir\>/buildpack/resources/cache.

to upload the buildpack, do "cf create-buildpack \<name\> outputdir/buildpack \<priority\>"

the process contains a test that verifies the fix before it outputs the artifact - you should see "PASS zones=604" in the terminal output. test the buildpack itself thoroughly in a lab environment by pushing a test app with each JDK you expect to use and checking the date behavior.

## further info
much more detail about the process and its output is available in [buildpack-tzdata-upgrade.md](buildpack-tzdata-upgrade.md) in this repo.
