#!/bin/sh
#sleep 1
#./test
#exit $?

pwd=`pwd`
echo $pwd\/$1
$pwd\/$1\/labcodes\/autotest.sh $pwd\/$1 $2
