package main

import (
 "bytes"
 "testing"
)

func TestDeriveIsDeterministicAndSalted(t *testing.T) {
 a:=derive("test-password",[]byte("0123456789abcdef"))
 b:=derive("test-password",[]byte("0123456789abcdef"))
 c:=derive("test-password",[]byte("fedcba9876543210"))
 if !bytes.Equal(a,b) { t.Fatal("same password and salt must produce same hash") }
 if bytes.Equal(a,c) { t.Fatal("different salts must produce different hashes") }
 if len(a)!=32 { t.Fatalf("unexpected hash length: %d",len(a)) }
}

func TestRandomToken(t *testing.T) {
 a,err:=random(24);if err!=nil{t.Fatal(err)}
 b,err:=random(24);if err!=nil{t.Fatal(err)}
 if a==b {t.Fatal("random tokens unexpectedly equal")}
 if len(a)<30 {t.Fatalf("token too short: %d",len(a))}
}
