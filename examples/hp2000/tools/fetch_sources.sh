#!/bin/sh
# Fetch HP's 2000E/F TSB sources from Bitsavers and rebuild src/*.asm (concatenated listing parts, CRs removed).
# The sources are Hewlett-Packard copyrighted; they are fetched on demand and not kept in version control.
set -e
cd "$(dirname "$0")/.."
URL=${TSB_SRC_URL:-https://ftp.mirrorservice.org/sites/www.bitsavers.org/bits/HP/tapes/2000tsb/TSB_E_F_srcs.tar}
mkdir -p tsb_src src
[ -f tsb_src/TSB_E_F_srcs.tar ] || curl -fL -o tsb_src/TSB_E_F_srcs.tar "$URL"
( cd tsb_src && tar xf TSB_E_F_srcs.tar )
D=tsb_src/TSB_E_F_srcs
for p in 24337:tsb_f_system 24338:tsb_f_loader_7900 24339:tsb_f_loader_2883 24343:tsb_f_iop \
         24280:tsb_e_system 24285:tsb_e_loader_util 24286:tsb_e_bootstrap; do
    n=${p%%:*}; o=${p##*:}
    cat $D/${n}-*.txt | tr -d '\r' > src/$o.asm
done
wc -l src/*.asm | tail -1
