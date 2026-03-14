#!/bin/bash
echo "=== Python Check ==="
which python3 2>/dev/null && python3 --version || echo "python3 NOT found"
which python 2>/dev/null && python --version 2>&1 || echo "python NOT found"

echo ""
echo "=== MDE/mdatp Status ==="
which mdatp 2>/dev/null && echo "mdatp found" || echo "mdatp NOT found"
if command -v mdatp &>/dev/null; then
    echo "--- mdatp health ---"
    mdatp health --field org_id 2>/dev/null || echo "Could not get org_id"
    mdatp health --field licensed 2>/dev/null || echo "Could not get licensed"
    mdatp health --field healthy 2>/dev/null || echo "Could not get healthy"
    mdatp health --field real_time_protection_enabled 2>/dev/null || echo "Could not get rtp"
fi

echo ""
echo "=== mdatp service status ==="
systemctl status mdatp 2>/dev/null | head -15 || echo "mdatp service not found"

echo ""
echo "=== OS Info ==="
cat /etc/os-release | head -5