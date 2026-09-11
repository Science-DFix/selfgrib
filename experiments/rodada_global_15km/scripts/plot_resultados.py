#!/usr/bin/env python3
"""
Gera plots comparando, lado a lado, a previsao GLOBAL de 15km (recortada
visualmente na area da America do Sul) com a previsao REGIONAL nativa
Voronoi-to-Voronoi (SouthAmerica), ambas em t=24h (2026-02-01_00Z), a
partir do mesmo experimento (rodada_global_15km).

Fontes:
  - Global 15km : forecast/2026013100/diag.*.nc      (malha x1.2621442, 2.621.442 celulas)
  - Regional     : recorte_SouthAmerica/forecast_run_native/diag.*.nc (233.732 celulas)

Uso: ajuste DIR_BASE abaixo (ou passe como argv[1]) e rode:
    python3 plot_resultados.py [DIR_BASE] [OUT_DIR]
"""
import sys
import numpy as np
import xarray as xr
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import cartopy.crs as ccrs
import cartopy.feature as cfeature
from scipy.interpolate import griddata

RAD2DEG = 180.0 / np.pi

DIR_BASE = sys.argv[1] if len(sys.argv) > 1 else "/mnt/dados2/SOURCE/rodada_global_15km"
OUT_DIR = sys.argv[2] if len(sys.argv) > 2 else "docs/resultados_15km_voronoi"

STATIC_GLOBAL = f"{DIR_BASE}/static/x1.2621442.static.nc"
STATIC_REGIONAL = f"{DIR_BASE}/recorte_SouthAmerica/SouthAmerica.static.nc"
DIAG_GLOBAL_FINAL = f"{DIR_BASE}/forecast/2026013100/diag.2026-02-01_00.00.00.nc"
DIAG_REGIONAL_FINAL = f"{DIR_BASE}/recorte_SouthAmerica/forecast_run_native/diag.2026-02-01_00.00.00.nc"
DIAG_GLOBAL_INIT = f"{DIR_BASE}/forecast/2026013100/diag.2026-01-31_00.00.00.nc"
DIAG_REGIONAL_INIT = f"{DIR_BASE}/recorte_SouthAmerica/forecast_run_native/diag.2026-01-31_00.00.00.nc"

# Extensao da malha regional SouthAmerica (com folga) -- usada tambem para
# recortar visualmente a malha global antes de regridar.
LON_MIN, LON_MAX = -92.0, -28.0
LAT_MIN, LAT_MAX = -60.0, 30.0
RES = 0.15  # graus, resolucao da grade regular de plot


def load_latlon(static_path):
    ds = xr.open_dataset(static_path, decode_times=False)
    lat = ds["latCell"].values * RAD2DEG
    lon = ds["lonCell"].values * RAD2DEG
    lon = np.where(lon > 180, lon - 360, lon)
    return lat, lon


def load_field(diag_path, varname):
    ds = xr.open_dataset(diag_path, decode_times=False)
    return np.asarray(ds[varname].values[0])


def regrid(lat, lon, values, margin=1.5):
    mask = (
        (lat >= LAT_MIN - margin) & (lat <= LAT_MAX + margin) &
        (lon >= LON_MIN - margin) & (lon <= LON_MAX + margin)
    )
    lon_g = np.arange(LON_MIN, LON_MAX, RES)
    lat_g = np.arange(LAT_MIN, LAT_MAX, RES)
    LON, LAT = np.meshgrid(lon_g, lat_g)
    Z = griddata((lon[mask], lat[mask]), values[mask], (LON, LAT), method="linear")
    return lon_g, lat_g, Z


def sparse_grid_for_quiver(lon_g, lat_g, step=8):
    return slice(None, None, step), slice(None, None, step)


def add_map(ax):
    ax.add_feature(cfeature.COASTLINE, linewidth=0.6)
    ax.add_feature(cfeature.BORDERS, linewidth=0.4)
    ax.set_extent([LON_MIN, LON_MAX, LAT_MIN, LAT_MAX], crs=ccrs.PlateCarree())
    gl = ax.gridlines(draw_labels=True, linewidth=0.3, alpha=0.5)
    gl.top_labels = False
    gl.right_labels = False


def plot_pair(field_name, title, cmap, unit, global_data, regional_data,
              vmin=None, vmax=None, wind=None, levels=None, out_name=None):
    """global_data / regional_data: (lon_g, lat_g, Z)"""
    fig, axes = plt.subplots(
        1, 2, figsize=(14, 6), subplot_kw={"projection": ccrs.PlateCarree()}
    )
    panels = [("Global 15km (recorte visual)", global_data), ("Regional nativo Voronoi-to-Voronoi", regional_data)]
    mesh = None
    for ax, (subtitle, (lon_g, lat_g, Z, U, V)) in zip(axes, panels):
        add_map(ax)
        mesh = ax.contourf(
            lon_g, lat_g, Z, levels=levels or 20, cmap=cmap,
            vmin=vmin, vmax=vmax, transform=ccrs.PlateCarree(), extend="both",
        )
        if U is not None:
            sl = sparse_grid_for_quiver(lon_g, lat_g)
            ax.quiver(
                lon_g[sl[1]], lat_g[sl[0]], U[sl], V[sl],
                transform=ccrs.PlateCarree(), scale=300, width=0.002, color="black",
            )
        ax.set_title(subtitle, fontsize=11)
    fig.suptitle(f"{title} — 2026-01-31 00Z + 24h", fontsize=13)
    cbar = fig.colorbar(mesh, ax=axes, orientation="horizontal", fraction=0.05, pad=0.08, shrink=0.6)
    cbar.set_label(unit)
    out_path = f"{OUT_DIR}/{out_name}"
    fig.savefig(out_path, dpi=140, bbox_inches="tight")
    plt.close(fig)
    print(f"[ OK ] {out_path}")


def main():
    import os
    os.makedirs(OUT_DIR, exist_ok=True)

    print("--- carregando coordenadas ---")
    lat_g_mesh, lon_g_mesh = load_latlon(STATIC_GLOBAL)
    lat_r_mesh, lon_r_mesh = load_latlon(STATIC_REGIONAL)

    def gg(varname, diag_final=DIAG_GLOBAL_FINAL):
        return regrid(lat_g_mesh, lon_g_mesh, load_field(diag_final, varname))

    def gr(varname, diag_final=DIAG_REGIONAL_FINAL):
        return regrid(lat_r_mesh, lon_r_mesh, load_field(diag_final, varname))

    # --- 1. MSLP + vento 10m ---
    print("--- MSLP + vento10m ---")
    lon_g, lat_g, mslp_g = gg("mslp")
    _, _, u10_g = gg("u10")
    _, _, v10_g = gg("v10")
    lon_r, lat_r, mslp_r = gr("mslp")
    _, _, u10_r = gr("u10")
    _, _, v10_r = gr("v10")
    plot_pair(
        "mslp", "Pressao ao nivel do mar (hPa) + vento 10m", "viridis", "hPa",
        (lon_g, lat_g, mslp_g / 100.0, u10_g, v10_g),
        (lon_r, lat_r, mslp_r / 100.0, u10_r, v10_r),
        out_name="01_mslp_vento10m_24h.png",
    )

    # --- 2. Temperatura 2m ---
    print("--- Temperatura 2m ---")
    lon_g, lat_g, t2m_g = gg("t2m")
    lon_r, lat_r, t2m_r = gr("t2m")
    plot_pair(
        "t2m", "Temperatura a 2m (C)", "RdYlBu_r", "C",
        (lon_g, lat_g, t2m_g - 273.15, None, None),
        (lon_r, lat_r, t2m_r - 273.15, None, None),
        out_name="02_temperatura_2m_24h.png",
    )

    # --- 3. Geopotencial 500hPa + vento 500hPa ---
    print("--- Geopotencial + vento 500hPa ---")
    lon_g, lat_g, z500_g = gg("height_500hPa")
    _, _, u500_g = gg("uzonal_500hPa")
    _, _, v500_g = gg("umeridional_500hPa")
    lon_r, lat_r, z500_r = gr("height_500hPa")
    _, _, u500_r = gr("uzonal_500hPa")
    _, _, v500_r = gr("umeridional_500hPa")
    plot_pair(
        "z500", "Altura geopotencial 500hPa (m) + vento", "cividis", "m",
        (lon_g, lat_g, z500_g, u500_g, v500_g),
        (lon_r, lat_r, z500_r, u500_r, v500_r),
        out_name="03_geopotencial_vento500_24h.png",
    )

    # --- 4. Precipitacao acumulada 24h ---
    print("--- Precipitacao acumulada 24h ---")
    def precip(diag_final, diag_init, lat, lon):
        rc0 = load_field(diag_init, "rainc"); rn0 = load_field(diag_init, "rainnc")
        rc1 = load_field(diag_final, "rainc"); rn1 = load_field(diag_final, "rainnc")
        acc = (rc1 - rc0) + (rn1 - rn0)
        return regrid(lat, lon, acc)
    lon_g, lat_g, prec_g = precip(DIAG_GLOBAL_FINAL, DIAG_GLOBAL_INIT, lat_g_mesh, lon_g_mesh)
    lon_r, lat_r, prec_r = precip(DIAG_REGIONAL_FINAL, DIAG_REGIONAL_INIT, lat_r_mesh, lon_r_mesh)
    plot_pair(
        "precip", "Precipitacao acumulada em 24h (mm)", "gist_ncar", "mm",
        (lon_g, lat_g, np.clip(prec_g, 0, None), None, None),
        (lon_r, lat_r, np.clip(prec_r, 0, None), None, None),
        vmin=0, out_name="04_precipitacao_acumulada_24h.png",
    )

    # --- 5. CAPE ---
    print("--- CAPE ---")
    lon_g, lat_g, cape_g = gg("cape")
    lon_r, lat_r, cape_r = gr("cape")
    plot_pair(
        "cape", "CAPE (J/kg)", "turbo", "J/kg",
        (lon_g, lat_g, np.clip(cape_g, 0, None), None, None),
        (lon_r, lat_r, np.clip(cape_r, 0, None), None, None),
        vmin=0, out_name="05_cape_24h.png",
    )

    # --- 6. OLR ---
    print("--- OLR ---")
    lon_g, lat_g, olr_g = gg("olrtoa")
    lon_r, lat_r, olr_r = gr("olrtoa")
    plot_pair(
        "olr", "Radiacao de onda longa emergente (W/m2)", "gray_r", "W/m2",
        (lon_g, lat_g, olr_g, None, None),
        (lon_r, lat_r, olr_r, None, None),
        out_name="06_olr_24h.png",
    )

    print("=== CONCLUIDO ===")


if __name__ == "__main__":
    main()
