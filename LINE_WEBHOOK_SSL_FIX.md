# LINE Webhook SSL Connection Error - Fix Guide

## Problem Summary

LINE's webhook verification is failing with "SSL connection error" because your server is sending a certificate chain that ends with the **self-signed Sectigo R46 root**, which LINE's webhook bot doesn't trust yet.

## Root Cause

Your current certificate chain:
```
*.cxbox.io (server cert)
  ↓ signed by
Sectigo Public Server Authentication CA DV R36 (intermediate)
  ↓ signed by
Sectigo Public Server Authentication Root R46 (SELF-SIGNED) ❌
```

LINE's webhook verification bot doesn't have the new Sectigo R46 root in its trusted root store, causing the SSL connection to fail.

## Solution

Replace the self-signed R46 root with the **cross-signed R46 root** (signed by AAA Certificate Services), which chains to USERTrust RSA CA that LINE trusts.

### Target Certificate Chain:

```
*.cxbox.io (server cert)
  ↓ signed by
Sectigo Public Server Authentication CA DV R36 (intermediate)
  ↓ signed by
Sectigo Public Server Authentication Root R46 (CROSS-SIGNED by AAA) ✅
  ↓ signed by
AAA Certificate Services / USERTrust RSA CA (trusted by LINE)
```

## Step-by-Step Fix

### 1. Download the Cross-Signed R46 Certificate

Two cross-signed R46 root certificates are available in this repository:

**Option A (RECOMMENDED):** `sectigo-r36-intermediate-cross-signed.crt`
- Subject: Sectigo Public Server Authentication Root R46
- Issuer: **USERTrust RSA Certification Authority**
- Valid until: 2038
- This is the most widely trusted option

**Option B:** `sectigo-r46-cross-signed-by-aaa.crt`
- Subject: Sectigo Public Server Authentication Root R46
- Issuer: AAA Certificate Services (Comodo CA Limited)
- Valid until: December 31, 2028

Use **Option A** (USERTrust) as it has the widest compatibility.

### 2. Rebuild Your Certificate Chain

You need to create a new fullchain file with this order:

```bash
# On your server (standalone.cxbox.io):

# 1. Your server certificate (*.cxbox.io)
# 2. Intermediate certificate (Sectigo R36)
# 3. Cross-signed root (R46 signed by USERTrust) - USE THIS ONE!

cat server_cert.crt \
    sectigo-r36-intermediate.crt \
    sectigo-r36-intermediate-cross-signed.crt \
    > fullchain-for-line.pem
```

**Alternative:** If you only have the server cert and need to build the complete chain:
```bash
cat server_cert.crt \
    sectigo-r36-intermediate-cross-signed.crt \
    > fullchain-for-line.pem
```

The cross-signed certificate (`sectigo-r36-intermediate-cross-signed.crt`) already contains the R46→USERTrust chain.

**Important:** 
- **REMOVE** the self-signed R46 root from your chain
- **ADD** the cross-signed R46 root instead

### 3. Update Nginx Configuration

Update your nginx SSL configuration to use the new fullchain:

```nginx
ssl_certificate /path/to/fullchain-for-line.pem;
ssl_certificate_key /path/to/privkey.pem;
```

### 4. Reload Nginx

```bash
sudo nginx -t && sudo nginx -s reload
```

### 5. Verify the Fix

Test the certificate chain:

```bash
# Should show "Verify return code: 0 (ok)"
echo | openssl s_client -connect standalone.cxbox.io:443 -servername standalone.cxbox.io 2>&1 | grep "Verify return code"

# Check the certificate chain includes AAA Certificate Services
echo | openssl s_client -connect standalone.cxbox.io:443 -servername standalone.cxbox.io 2>&1 | grep -E "s:|i:"
```

You should see the chain ending with AAA Certificate Services or USERTrust RSA CA, NOT the self-signed R46.

### 6. Test LINE Webhook Verification

Go back to LINE Developers console and click "Verify" again. It should now succeed.

## Why This Works

- **AAA Certificate Services** (also known as Comodo CA) is a legacy root that's been trusted by all major platforms since 2000
- **USERTrust RSA CA** is widely trusted across all systems
- LINE's webhook bot trusts these older roots, but doesn't yet trust the newer Sectigo R46 self-signed root
- The cross-signed version creates a bridge from your certificate to a root that LINE trusts

## Alternative Solution: Use Let's Encrypt

If the above doesn't work or is too complex, consider switching to Let's Encrypt certificates:

```bash
# Let's Encrypt uses widely-trusted ISRG Root X1
sudo certbot certonly --nginx -d standalone.cxbox.io
```

Let's Encrypt certificates are automatically trusted by LINE and most other webhook services.

## Troubleshooting

If you still get errors after applying the fix:

1. **Verify you removed the self-signed R46:**
   ```bash
   openssl s_client -connect standalone.cxbox.io:443 -servername standalone.cxbox.io < /dev/null 2>&1 | grep "Sectigo Public Server Authentication Root R46"
   ```
   Check the issuer - it should be "AAA Certificate Services", not "Sectigo Limited"

2. **Check certificate order:** Certificates must be in the correct order (server → intermediate → cross-signed root)

3. **Restart nginx completely:** Sometimes a reload isn't enough
   ```bash
   sudo systemctl restart nginx
   ```

## Files in This Repository

- `sectigo-r36-intermediate-cross-signed.crt` - **RECOMMENDED** - R46 root cross-signed by USERTrust RSA CA
- `sectigo-r46-cross-signed-by-aaa.crt` - Alternative - R46 root cross-signed by AAA Certificate Services

## Quick Summary

**The Problem:** You're sending a self-signed R46 root that LINE doesn't trust.

**The Fix:** Replace it with the cross-signed R46 root (signed by USERTrust) that LINE trusts.

**Action Required:** Update your nginx fullchain.pem on the server to use `sectigo-r36-intermediate-cross-signed.crt` instead of the self-signed R46 root.
