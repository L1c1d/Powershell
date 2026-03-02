#  Checks to see if memory integrity is on or off.
#  Windows Security > Device Security > Core isolation > Memory integrity

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
$val = Get-ItemProperty -Path $regPath -Name Enabled -ErrorAction SilentlyContinue

if ($val.Enabled -eq 1) {
    "Memory Integrity: ON"
}
else {
    "Memory Integrity: OFF"
}