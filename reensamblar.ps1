# Junta los archivos que se partieron en trozos (*.partNNN) para poder subirlos a GitHub,
# que no admite archivos de mas de 100 MB. Ejecutar una vez despues de clonar/descargar:
#   powershell -ExecutionPolicy Bypass -File reensamblar.ps1

$root = $PSScriptRoot
$firsts = Get-ChildItem -Path $root -Recurse -File -Filter '*.part001'
foreach ($first in $firsts) {
    $target = $first.FullName -replace '\.part001$', ''
    $base = [IO.Path]::GetFileName($target)
    $parts = Get-ChildItem -Path $first.DirectoryName -File |
        Where-Object { $_.Name -match ('^' + [regex]::Escape($base) + '\.part\d{3}$') } |
        Sort-Object Name
    if (Test-Path $target) {
        Write-Host "Ya existe, se omite: $target"
        continue
    }
    Write-Host "Reensamblando $target ($($parts.Count) trozos)..."
    $out = [IO.File]::Create($target)
    try {
        foreach ($p in $parts) {
            $in = [IO.File]::OpenRead($p.FullName)
            try { $in.CopyTo($out) } finally { $in.Dispose() }
        }
    } finally { $out.Dispose() }
}
Write-Host "Listo."
