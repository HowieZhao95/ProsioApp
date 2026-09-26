# Local development signing

Ad-hoc signing (`-`) changes the code hash on every build, so macOS drops the Microphone,
Accessibility and Input Monitoring grants after each rebuild. Prosio's Debug builds are instead
signed with a self-signed identity named **Prosio Local Development**, whose designated
requirement (`identifier "app.prosio.mac" and certificate leaf = H"…"`) stays stable across
rebuilds, so grants persist.

Create the identity once per machine (login keychain only; no trust settings are changed —
`security find-identity` shows it as CSSMERR_TP_NOT_TRUSTED, which is fine for local codesign):

```bash
cat > /tmp/prosio-cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Prosio Local Development
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/prosio.key -out /tmp/prosio.pem -days 3650 -config /tmp/prosio-cert.cnf
PW=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey /tmp/prosio.key -in /tmp/prosio.pem -name "Prosio Local Development" \
  -out /tmp/prosio.p12 -passout pass:$PW -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import /tmp/prosio.p12 -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
rm /tmp/prosio.key /tmp/prosio.p12
```

Release builds will use a Developer ID certificate instead.
