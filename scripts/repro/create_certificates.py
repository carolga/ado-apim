"""Generate a disposable private CA and encrypted APIM gateway PFX locally."""

import argparse
from datetime import datetime, timedelta, timezone
from getpass import getpass
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", default="mcp.repro.test")
    parser.add_argument("--output-directory", type=Path, default=Path(".local/repro"))
    args = parser.parse_args()

    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

    directory = args.output_directory
    if any((directory / name).exists() for name in ("ca.pem", "gateway.pfx")):
        parser.error("Output certificates already exist; choose a fresh directory.")
    password = getpass("Password for the gateway PFX (at least 12 characters): ")
    if len(password) < 12:
        parser.error("Use a PFX password of at least 12 characters.")
    if password != getpass("Confirm PFX password: "):
        parser.error("Passwords do not match.")

    now = datetime.now(timezone.utc)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "ADO repro CA")])
    ca = (
        x509.CertificateBuilder()
        .subject_name(ca_name).issuer_name(ca_name)
        .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=14))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(False, False, False, False, False, True, True, None, None),
            critical=True,
        )
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()), False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), False)
        .sign(ca_key, hashes.SHA256())
    )
    leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    leaf = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, args.hostname)]))
        .issuer_name(ca.subject).public_key(leaf_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=7))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(args.hostname)]), False)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), False)
        .add_extension(
            x509.KeyUsage(True, False, True, False, False, False, False, None, None),
            critical=True,
        )
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(leaf_key.public_key()), False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), False)
        .sign(ca_key, hashes.SHA256())
    )
    encryption = (
        serialization.PrivateFormat.PKCS12.encryption_builder()
        .kdf_rounds(20000)
        .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
        .hmac_hash(hashes.SHA1())
        .build(password.encode("utf-8"))
    )
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "gateway.pfx").write_bytes(
        pkcs12.serialize_key_and_certificates(
            b"ado-repro-gateway", leaf_key, leaf, [ca], encryption
        )
    )
    (directory / "ca.pem").write_bytes(ca.public_bytes(serialization.Encoding.PEM))
    print(f"Created {directory / 'ca.pem'} (public CA only) and encrypted gateway.pfx.")
    print("The CA private key was not saved. Certificates are disposable and expire.")


if __name__ == "__main__":
    main()
