#!/bin/zsh
set -e
cd "${0:A:h}"
mkdir -p bin
swiftc -parse-as-library -O -o bin/rec rec.swift
swiftc -O -o bin/drive drive.swift
echo "Built bin/rec and bin/drive"
