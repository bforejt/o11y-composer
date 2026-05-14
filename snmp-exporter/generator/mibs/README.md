# Vendor MIB Files

Place vendor-specific MIB files here for the snmp_exporter generator.

## Palo Alto (PAN-OS)

Required MIBs for the `paloalto_gp` module:

- `PAN-COMMON-MIB.mib` — Base enterprise OID definitions
- `PAN-GLOBALPROTECT-MIB.mib` — GlobalProtect gateway utilization table
- `PAN-PRODUCTS-MIB.mib` — Product identity OIDs (dependency)

### How to obtain

**From a PAN-OS device:**

```
https://<firewall-ip>/api/?type=export&category=tech-support
```

Or via CLI:

```
scp admin@<firewall-ip>:/opt/pancfg/mgmt/snmp/mibs/*.mib ./
```

**From Palo Alto support portal:**

1. Log into https://support.paloaltonetworks.com
2. Navigate to Updates → Dynamic Updates or search for "SNMP MIB"
3. Download the MIB package for your PAN-OS version

## Notes

- Standard IETF MIBs (IF-MIB, SNMPv2-MIB, etc.) ship with the generator image.
- MIB files may be subject to vendor license terms — check before committing.
