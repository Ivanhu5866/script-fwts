#!/bin/bash
# Copyright (C) 2015-2021 Canonical
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
shopt -s -o nounset
SOURCE_REPO="https://github.com/fwts/fwts"
EDITOR=gedit

if [ $# -eq 0 ] ; then
	echo "Please provide release version, ex. 16.01.00."
	exit 1
fi

# == Reminder messages and prerequisites ==
RELEASE_VERSION=${1}
echo "FWTS V${RELEASE_VERSION} is to be released."
echo "Did you update fwts's mkpackage.sh vs. https://wiki.ubuntu.com/Releases?"
read -p "Please [ENTER] to continue or Ctrl+C to abort"

echo ""
echo "Please confirm upload rights of kernel.ubuntu.com and fwts.ubuntu.com"
read -p "Please [ENTER] to continue or Ctrl+C to abort"

# == Prepare the source code ==
# download fwts source code
if [ -e fwts ] ; then
	echo "fwts directory exists! aborting..."
	exit 1
fi

git clone https://github.com/fwts/fwts
cd fwts/

# generate changelog based on the previous git tag..HEAD
git shortlog $(git describe --abbrev=0 --tags)..HEAD | sed "s/^     /  */g" > ../fwts_${RELEASE_VERSION}_release_note

# add the changelog to the changelog file
echo "1. ensure the format is correct, . names, max 80 characters per line etc."
echo "2. update the version, e.g: \"fwts (15.12.00-0ubuntu0) UNRELEASED; urgency=low\" to "
echo "   \"fwts (16.01.00-0ubuntu0) xenial; urgency=low\""

# TODO may need to pop a window for above messages
read -p "Please [ENTER] to continue or Ctrl+C to abort"

$EDITOR ../fwts_${RELEASE_VERSION}_release_note &
dch -i
# wait for copying to dch -i
echo "type \"done\" to continue..."
line=""
while true ; do
	read line
	if [ "$line" = "done" ] ; then
		break;
	fi
done

echo ""

# commit changelog
git add debian/changelog
git commit -s -m "debian: update changelog"

# update the version
./update_version.sh V${RELEASE_VERSION}

# == Build and publish ==
# commit the changelog file and the tag
git push upstream master
git push upstream master --tags

# create a temporary directory to generate the final tarball
mkdir fwts-tarball
cd fwts-tarball/
cp ../auto-packager/mk*sh .
./mktar.sh V${RELEASE_VERSION}

# copy the final fwts tarball to fwts.ubuntu.com
echo "ensure VPN is connected."
read -p "Please [ENTER] to continue or Ctrl+C to abort"

cd V${RELEASE_VERSION}/
scp fwts-V${RELEASE_VERSION}.tar.gz ivanhu@kernel-bastion-ps5:~/

# update SHA256 on fwts.ubuntu.com
echo "Run the following commands on fwts.ubuntu.com:"
echo "  1. ssh kernel-bastion-ps5.internal"
echo "  2. pe fwts"
echo "  3. juju scp /home/ivanhu/fwts-V${RELEASE_VERSION}.tar.gz 0:/srv/fwts.ubuntu.com/www/release/"
echo "  4. juju ssh 0"
echo "  5. cd /srv/fwts.ubuntu.com/www/release/"
echo "  6. sha256sum fwts-V${RELEASE_VERSION}.tar.gz >> SHA256SUMS"
echo "  7. exit"
echo ""

echo "type \"done\" to continue..."
line=""
while true ; do
	read line
	if [ "$line" = "done" ] ; then
		break;
	fi
done

# generate the source packages for all supported Ubuntu releases
cd ..
./mkpackage.sh V${RELEASE_VERSION}

# do ADT test
echo "do ADT test"
echo "sudo autopkgtest ./fwts_18.06.00-0ubuntu1.dsc -- null"
echo "..and check for the error status at the end of the test with:"
echo "echo \$?"
echo "0 is a pass, otherwise anything else is a fail."

echo "type \"done\" to continue..."
line=""
while true ; do
        read line
        if [ "$line" = "done" ] ; then
                break;
        fi
done

# upload the packages to the unstable-crack PPA to build
cd V${RELEASE_VERSION}

#dput ppa:firmware-testing-team/scratch */*es
dput ppa:firmware-testing-team/ppa-fwts-unstable-crack */*es
echo "Check build status @ https://launchpad.net/~firmware-testing-team/+archive/ubuntu/ppa-fwts-unstable-crack"

# finalize
echo "When the build finishes, please do the following:"
echo "  1. copy package to PPA https://launchpad.net/~canonical-fwts-team/+archive/ubuntu/fwts-release-builds"
echo "  2. copy packages to stage PPA (Firmware Test Suite (Stable))"
echo "  3. create a new release note page https://wiki.ubuntu.com/FirmwareTestSuite/ReleaseNotes/xx.xx.xx"
echo "  4. upload the new FWTS package to the Ubuntu universe archive"
echo "  5. update milestone on https://launchpad.net/fwts"
echo "  6. build fwts snap, https://launchpad.net/~firmware-testing-team/fwts/+snap/fwts"
echo "  7. email to fwts-devel and fwts-announce lists"
echo "  8. build new fwts-live"
