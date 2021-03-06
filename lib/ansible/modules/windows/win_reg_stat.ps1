#!powershell
# This file is part of Ansible
#
# Ansible is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

# WANT_JSON
# POWERSHELL_COMMON

$ErrorActionPreference = "Stop"

$params = Parse-Args $args -supports_check_mode $true
$key = Get-AnsibleParam $params "key" -FailIfEmpty $true
$property = Get-AnsibleParam $params "property" -FailIfEmpty $false -default $null

$result = @{
    win_reg_stat = @{}
    changed = $false
    warnings = @()
}

Function Get-NetHiveName($hive) {
    # Will also check that the hive passed in the path is a known hive
    switch ($hive.ToUpper()) {
        "HKCR" {"ClassesRoot"}
        "HKCC" {"CurrentConfig"}
        "HKCU" {"CurrentUser"}
        "HKLM" {"LocalMachine"}
        "HKU" {"Users"}        
        default {"unsupported"}
    }
}

Function Get-PropertyType($hive, $path, $property) {
    $type = (Get-Item REGISTRY::$hive\$path).GetValueKind($property)
    switch ($type) {
        "Binary" {"REG_BINARY"}
        "String" {"REG_SZ"}
        "DWord" {"REG_DWORD"}
        "QWord" {"REG_QWORD"}
        "MultiString" {"REG_MULTI_SZ"}
        "ExpandString" {"REG_EXPAND_SZ"}
        "None" {"REG_NONE"}
        default {"Unknown"}
    }
}

Function Get-PropertyObject($hive, $net_hive, $path, $property) {
    $value = (Get-ItemProperty REGISTRY::$hive\$path).$property
    $type = Get-PropertyType -hive $hive -path $path -property $property
    If ($type -eq 'REG_EXPAND_SZ') {
        $raw_value = [Microsoft.Win32.Registry]::$net_hive.OpenSubKey($path).GetValue($property, $false, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } ElseIf ($type -eq 'REG_BINARY' -or $type -eq 'REG_NONE') {
        $raw_value = @()
        foreach ($byte in $value) {
            $hex_value = ('{0:x}' -f $byte).PadLeft(2, '0')
            $raw_value += "0x$hex_value"
        }
    } Else {
        $raw_value = $value
    }

    $object = New-Object PSObject @{
        raw_value = $raw_value
        value = $value
        type = $type
    }

    $object
}

Function Test-RegistryProperty($hive, $path, $property) {
    Try {
        $type = (Get-Item REGISTRY::$hive\$path).GetValueKind($property)
    } Catch {
        $type = $null
    }

    If ($type -eq $null) {
        $false
    } Else {
        $true
    }
}

# Will validate the key parameter to make sure it matches known format
if ($key -match "^([a-zA-Z_]*):\\(.*)$") {
    $hive = $matches[1]
    $path = $matches[2]
} else {
    Fail-Json $result "key does not match format 'HIVE:\KEY_PATH'"
}

# Used when getting the actual REG_EXPAND_SZ value as well as checking the hive is a known value
$net_hive = Get-NetHiveName -hive $hive
if ($net_hive -eq 'unsupported') {
    Fail-Json $result "the hive in key is '$hive'; must be 'HKCR', 'HKCC', 'HKCU', 'HKLM' or 'HKU'"
}

if (Test-Path REGISTRY::$hive\$path) {
    if ($property -eq $null) {
        $property_info = @{}
        $properties = Get-ItemProperty REGISTRY::$hive\$path

        foreach ($property in $properties.PSObject.Properties) {
            # Powershell adds in some metadata we need to filter out
            $real_property = Test-RegistryProperty -hive $hive -path $path -property $property.Name
            if ($real_property -eq $true) {
                $property_object = Get-PropertyObject -hive $hive -net_hive $net_hive -path $path -property $property.Name 
                $property_info.Add($property.Name, $property_object)
            }            
        }

        $sub_keys = @()
        $sub_keys_raw = Get-ChildItem REGISTRY::$hive\$path -ErrorAction SilentlyContinue

        foreach ($sub_key in $sub_keys_raw) {
            $sub_keys += $sub_key.PSChildName
        }

        $result.win_reg_stat.exists = $true
        $result.win_reg_stat.sub_keys = $sub_keys
        $result.win_reg_stat.properties = $property_info
    } else {
        $exists = Test-RegistryProperty -hive $hive -path $path -property $property
        if ($exists -eq $true) {
            $propertyObject = Get-PropertyObject -hive $hive -net_hive $net_hive -path $path -property $property
            $result.win_reg_stat.exists = $true
            $result.win_reg_stat.raw_value = $propertyObject.raw_value
            $result.win_reg_stat.value = $propertyObject.value
            $result.win_reg_stat.type = $propertyObject.type
        } else {
            $result.win_reg_stat.exists = $false
        }
    }
} else {
    $result.win_reg_stat.exists = $false
}

Exit-Json $result
