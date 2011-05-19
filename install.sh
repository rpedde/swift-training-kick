#!/bin/bash

set +x

exec >/tmp/firstboot.local
exec 2>&1

touch /tmp/foo

