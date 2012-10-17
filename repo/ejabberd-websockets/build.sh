#!/bin/sh
erl -pa /usr/lib/ejabberd/ebin -pz ebin -make
sudo cp ebin/*.beam /lib/ejabberd/ebin/
