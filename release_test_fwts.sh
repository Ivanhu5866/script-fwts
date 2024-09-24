#!/bin/bash

#copy this script along with "cp -r fwts" at the same folder
#chmod +x release_test_fwts.sh
#./release_test_fwts.sh 20.05.04 

RELEASES="bionic focal jammy noble oracular"
FWTS=fwts


if [ $# -eq 0 ] ; then
	echo "Please provide release version, ex. 18.09.00."
	exit 1
fi

RELEASE_VERSION=${1}

mk_package()
{
	rel=$1

	rm -rf $RELEASE_VERSION/$rel
  	mkdir -p $RELEASE_VERSION/$rel
	cp -r $FWTS $RELEASE_VERSION/$rel
	cp fwts_${RELEASE_VERSION}.orig.tar.gz $RELEASE_VERSION/$rel

	pushd $RELEASE_VERSION/$rel/$FWTS >& /dev/null

	deb_topline=`head -1 debian/changelog`
	deb_release=`echo $deb_topline | cut -f3 -d' '`
	if [ "x$rel;" = "x$deb_release" ]; then
		suffix=''
	else
		suffix="~`echo $rel | cut -c1`"
	fi
	
	#	
	# Mungify changelog hack
	#
	sed "s/) $deb_release/$suffix) $rel;/" debian/changelog > debian/changelog.new
	mv debian/changelog.new debian/changelog

        #
        # control hack
        # remove dh-dkms dependency for those releases which are on need
        #
        if [ "$rel" = "bionic" -o "$rel" = "focal" -o "$rel" = "jammy" ]; then
                sed '/dh-dkms,/d' debian/control > debian/control.new
                mv debian/control.new debian/control
        fi

  	echo 'y' | debuild -S -sa -I -i
#	rm -rf $FWTS
	popd >& /dev/null
}

#git clone git://kernel.ubuntu.com/hwe/fwts.git
pushd $FWTS >& /dev/null
#cd fwts/

dch -i
# commit changelog
git add debian/changelog
git commit -s -m "debian: update changelog"

# update the version
./update_version.sh V${RELEASE_VERSION}

# generate tarball
git clean -fd
rm -rf m4/*
rm -f ../fwts_*

git archive V${RELEASE_VERSION} -o ../fwts_${RELEASE_VERSION}.orig.tar
gzip ../fwts_${RELEASE_VERSION}.orig.tar
popd >& /dev/null

for I in $RELEASES 
do
	echo Building package for release $I with version $RELEASE_VERSION
	mk_package $I
done

# build the debian package
#debuild -S -sa -I -i

cd $RELEASE_VERSION
echo "dput ppa:firmware-testing-team/scratch."
dput ppa:firmware-testing-team/scratch */*es
