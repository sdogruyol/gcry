#!/bin/sh
# Proof runs, one run per lock hold: late mover base x10 then fix x100
# interleaved with forced-fill and early-mover arms.
R=/home/naruto/playground/.scratch/Reg21d
cd $R
./loop.sh lmvbase 10 lmv122base
./loop.sh fmvbase 5 fmv122
./loop.sh fmvfix 10 fmv122fix
i=0
while [ $i -lt 10 ]; do
  ./loop.sh lmvfix 10 lmv122fix
  ./loop.sh mvfix 3 mv122fix
  i=$((i+1))
done
echo CAMPAIGN DONE
