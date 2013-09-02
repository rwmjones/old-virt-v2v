#!/bin/bash

# A utility to create a set of patch files from git for import into a spec file

i=$1
prefix=$2

if [ -z "$i" -o -z "$prefix" ]; then
    echo "Usage: $0 <start index> <prefix>" > /dev/stderr
    exit 1
fi

while read commit; do
    msg=`git log --oneline $commit^..$commit`
    short=`echo $msg | awk '{print $1}'`
    path=`printf "%s-%02i-%s.patch" "$prefix" "$i" "$short"`

    # Display the spec file fragment
    echo \# $msg
    printf "%-10s%s\n" "Patch$i:" "$path"
    echo

    # Write the patch file
    git show "$commit" > $path

    ((i++))
done
