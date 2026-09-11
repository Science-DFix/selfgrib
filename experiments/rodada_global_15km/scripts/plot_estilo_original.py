#!/usr/bin/env python3
"""
Replica, para a previsao regional SouthAmerica recortada da malha GLOBAL de
15km (rota nativa Voronoi-to-Voronoi), os mesmos 9 graficos que ja existem
em docs/resultados_voronoi/ para o caso original de 60km -- mesmo estilo
(sem gridlines/eixos numerados, mesmos titulos, mesmos nomes de arquivo),
para permitir comparacao direta "antes (60km) / depois (15km)".

Uso: python3 plot_estilo_original.py [DIR_BASE] [OUT_DIR] [SUBDIR_REGIONAL] [ROTULO_MALHA]
  SUBDIR_REGIONAL: nome do subdiretorio dentro de DIR_BASE com o recorte
                   regional (default: recorte_SouthAmerica, o caso 15km)
  ROTULO_MALHA   : texto entre parenteses no titulo (default: "malha global 15km")
"""
import sys
import os
import numpy as np
import xarray as xr
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from matplotlib.colors import BoundaryNorm, ListedColormap
import cartopy.crs as ccrs
import cartopy.feature as cfeature
from scipy.interpolate import griddata

RAD2DEG = 180.0 / np.pi

DIR_BASE = sys.argv[1] if len(sys.argv) > 1 else "/mnt/dados2/SOURCE/rodada_global_15km"
OUT_DIR = sys.argv[2] if len(sys.argv) > 2 else "docs/resultados_voronoi_15km"
SUBDIR_REGIONAL = sys.argv[3] if len(sys.argv) > 3 else "recorte_SouthAmerica"
ROTULO_MALHA = sys.argv[4] if len(sys.argv) > 4 else "malha global 15km"

DIR_REG = f"{DIR_BASE}/{SUBDIR_REGIONAL}"
STATIC = f"{DIR_REG}/SouthAmerica.static.nc"
FCST_DIR = f"{DIR_REG}/forecast_run_native"
DIAG_INIT = f"{FCST_DIR}/diag.2026-01-31_00.00.00.nc"
DIAG_FINAL = f"{FCST_DIR}/diag.2026-02-01_00.00.00.nc"
VALID_LABEL = "2026-02-01_00"

TIMES = ["2026-01-31_00", "2026-01-31_03", "2026-01-31_06", "2026-01-31_09",
         "2026-01-31_12", "2026-01-31_15", "2026-01-31_18", "2026-01-31_21",
         "2026-02-01_00"]
HOURS = [0, 3, 6, 9, 12, 15, 18, 21, 24]

LON_MIN, LON_MAX = -92.0, -28.0
LAT_MIN, LAT_MAX = -60.0, 30.0
RES = 0.12


def load_static():
    return xr.open_dataset(STATIC, decode_times=False)


def latlon_deg(ds):
    lat = ds["latCell"].values * RAD2DEG
    lon = ds["lonCell"].values * RAD2DEG
    lon = np.where(lon > 180, lon - 360, lon)
    return lat, lon


def load_field(path, varname):
    ds = xr.open_dataset(path, decode_times=False)
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


def new_fig():
    fig = plt.figure(figsize=(8, 9))
    ax = plt.axes(projection=ccrs.PlateCarree())
    ax.set_extent([LON_MIN, LON_MAX, LAT_MIN, LAT_MAX], crs=ccrs.PlateCarree())
    ax.add_feature(cfeature.COASTLINE, linewidth=0.8)
    ax.add_feature(cfeature.BORDERS, linewidth=0.5, edgecolor="gray")
    ax.set_xticks([])
    ax.set_yticks([])
    return fig, ax


def save(fig, name):
    os.makedirs(OUT_DIR, exist_ok=True)
    out_path = f"{OUT_DIR}/{name}"
    fig.savefig(out_path, dpi=130, bbox_inches="tight")
    plt.close(fig)
    print(f"[ OK ] {out_path}")


def plot_00_dominio_terreno(lat, lon, ter, bdy):
    fig, ax = new_fig()
    lon_g, lat_g, Z = regrid(lat, lon, ter)
    mesh = ax.contourf(
        lon_g, lat_g, np.clip(Z, 200, None), levels=np.linspace(200, 4800, 24),
        cmap="terrain", transform=ccrs.PlateCarree(), extend="both",
    )
    bmask = bdy > 0
    # malha 15km tem ~16x mais celulas por area que a 60km original -- pontos
    # bem menores e mais transparentes pra manter o anel pontilhado legivel
    # em vez de um anel solido grosso.
    ax.scatter(
        lon[bmask], lat[bmask], s=0.08, c="red", marker=".", alpha=0.5,
        transform=ccrs.PlateCarree(), zorder=5,
    )
    cbar = fig.colorbar(mesh, ax=ax, fraction=0.045, pad=0.04)
    cbar.set_label("Altitude do terreno (m)")
    ax.set_title(
        "Domínio SouthAmerica — terreno e zona de fronteira/relaxamento (LBC, vermelho)\n"
        f"rota nativa voronoi-to-voronoi ({ROTULO_MALHA})"
    )
    save(fig, "00_dominio_terreno_lbc.png")


def plot_01_malha_zoom(ds, cape):
    lat_v = ds["latVertex"].values * RAD2DEG
    lon_v = ds["lonVertex"].values * RAD2DEG
    lon_v = np.where(lon_v > 180, lon_v - 360, lon_v)
    verts_on_cell = ds["verticesOnCell"].values - 1
    n_edges = ds["nEdgesOnCell"].values
    lat_c = ds["latCell"].values * RAD2DEG
    lon_c = ds["lonCell"].values * RAD2DEG
    lon_c = np.where(lon_c > 180, lon_c - 360, lon_c)

    zoom_lon = (-65.0, -55.0)
    zoom_lat = (-8.0, 2.0)
    mask = (
        (lat_c >= zoom_lat[0]) & (lat_c <= zoom_lat[1]) &
        (lon_c >= zoom_lon[0]) & (lon_c <= zoom_lon[1])
    )
    idxs = np.where(mask)[0]

    polys = []
    vals = []
    for i in idxs:
        n = n_edges[i]
        vids = verts_on_cell[i, :n]
        poly_lon = lon_v[vids]
        poly_lat = lat_v[vids]
        if poly_lon.max() - poly_lon.min() > 180:
            continue  # evita poligono cruzando antimeridiano (nao ocorre aqui, defensivo)
        polys.append(np.column_stack([poly_lon, poly_lat]))
        vals.append(cape[i])

    fig, ax = plt.subplots(figsize=(9.5, 6))
    coll = PolyCollection(polys, array=np.array(vals), cmap="viridis", edgecolors="black", linewidths=0.3)
    ax.add_collection(coll)
    ax.set_xlim(zoom_lon)
    ax.set_ylim(zoom_lat)
    ax.set_xticks([])
    ax.set_yticks([])
    cbar = fig.colorbar(coll, ax=ax, fraction=0.045, pad=0.04)
    cbar.set_label(f"CAPE (J/kg), válido {VALID_LABEL} (+24h)")
    ax.set_title(
        "Malha nativa MPAS (células de Voronoi reais), zoom Amazônia central\n"
        f"rota nativa — sem grade lat-lon intermediária ({ROTULO_MALHA})"
    )
    save(fig, "01_malha_nativa_zoom_cape.png")


def plot_02_mslp(lat, lon):
    mslp = load_field(DIAG_FINAL, "mslp") / 100.0
    u10 = load_field(DIAG_FINAL, "u10")
    v10 = load_field(DIAG_FINAL, "v10")
    lon_g, lat_g, Z = regrid(lat, lon, mslp)
    _, _, U = regrid(lat, lon, u10)
    _, _, V = regrid(lat, lon, v10)
    fig, ax = new_fig()
    mesh = ax.contourf(lon_g, lat_g, Z, levels=20, cmap="RdYlBu_r", transform=ccrs.PlateCarree())
    step = 10
    ax.quiver(
        lon_g[::step], lat_g[::step], U[::step, ::step], V[::step, ::step],
        transform=ccrs.PlateCarree(), scale=350, width=0.0022, color="black",
    )
    cbar = fig.colorbar(mesh, ax=ax, fraction=0.045, pad=0.04)
    cbar.set_label("Pressão ao nível do mar (hPa)")
    ax.set_title(f"MSLP + vento a 10m, válido {VALID_LABEL} (+24h)\nrota nativa voronoi-to-voronoi ({ROTULO_MALHA})")
    save(fig, "02_mslp_vento10m_24h.png")


def plot_03_t2m(lat, lon):
    t2m = load_field(DIAG_FINAL, "t2m") - 273.15
    lon_g, lat_g, Z = regrid(lat, lon, t2m)
    fig, ax = new_fig()
    mesh = ax.contourf(lon_g, lat_g, Z, levels=np.linspace(-4.5, 40.5, 21), cmap="nipy_spectral", transform=ccrs.PlateCarree(), extend="both")
    cbar = fig.colorbar(mesh, ax=ax, fraction=0.045, pad=0.04)
    cbar.set_label("Temperatura a 2m (°C)")
    ax.set_title(f"Temperatura a 2m, válido {VALID_LABEL} (+24h)\nrota nativa voronoi-to-voronoi ({ROTULO_MALHA})")
    save(fig, "03_temperatura_2m_24h.png")


def plot_04_z500(lat, lon):
    z500 = load_field(DIAG_FINAL, "height_500hPa")
    u500 = load_field(DIAG_FINAL, "uzonal_500hPa")
    v500 = load_field(DIAG_FINAL, "umeridional_500hPa")
    lon_g, lat_g, Z = regrid(lat, lon, z500)
    _, _, U = regrid(lat, lon, u500)
    _, _, V = regrid(lat, lon, v500)
    fig, ax = new_fig()
    mesh = ax.contourf(lon_g, lat_g, Z, levels=20, cmap="viridis", transform=ccrs.PlateCarree())
    step = 10
    ax.quiver(
        lon_g[::step], lat_g[::step], U[::step, ::step], V[::step, ::step],
        transform=ccrs.PlateCarree(), scale=600, width=0.0018, color="white",
    )
    cbar = fig.colorbar(mesh, ax=ax, fraction=0.045, pad=0.04)
    cbar.set_label("Altura geopotencial em 500 hPa (m)")
    ax.set_title(f"Altura geopotencial e vento em 500 hPa, válido {VALID_LABEL} (+24h)\nrota nativa voronoi-to-voronoi ({ROTULO_MALHA})")
    save(fig, "04_geopotencial_vento_500hPa_24h.png")


def plot_05_precip(lat, lon):
    rc0 = load_field(DIAG_INIT, "rainc"); rn0 = load_field(DIAG_INIT, "rainnc")
    rc1 = load_field(DIAG_FINAL, "rainc"); rn1 = load_field(DIAG_FINAL, "rainnc")
    acc = np.clip((rc1 - rc0) + (rn1 - rn0), 0, None)
    lon_g, lat_g, Z = regrid(lat, lon, acc)
    Z = np.clip(Z, 0, None)

    bounds = [0, 2, 10, 20, 40, 80, 150, 400]
    colors = ["#ffffff", "#f5d9f0", "#d896e0", "#e6007e", "#ff0000", "#ff8c00", "#00b400", "#00c8c8"]
    cmap = ListedColormap(colors)
    norm = BoundaryNorm(bounds, cmap.N, extend="max")

    fig, ax = new_fig()
    mesh = ax.contourf(lon_g, lat_g, Z, levels=bounds, colors=colors, norm=norm, transform=ccrs.PlateCarree(), extend="max")
    cbar = fig.colorbar(mesh, ax=ax, fraction=0.045, pad=0.04, boundaries=bounds, spacing="uniform")
    cbar.set_label("Precipitação acumulada em 24h (mm)")
    ax.set_title(f"Precipitação acumulada em 24h (rainc+rainnc)\nrota nativa voronoi-to-voronoi ({ROTULO_MALHA})")
    save(fig, "05_precipitacao_acumulada_24h.png")


def plot_06_cape(lat, lon):
    cape = load_field(DIAG_FINAL, "cape")
    lon_g, lat_g, Z = regrid(lat, lon, cape)
    Z = np.clip(Z, 0, None)
    fig, ax = new_fig()
    mesh = ax.contourf(lon_g, lat_g, Z, levels=np.linspace(0, 3600, 21), cmap="gist_heat_r", transform=ccrs.PlateCarree(), extend="max")
    cbar = fig.colorbar(mesh, ax=ax, fraction=0.045, pad=0.04)
    cbar.set_label("CAPE (J/kg)")
    ax.set_title(f"CAPE, válido {VALID_LABEL} (+24h)\nrota nativa voronoi-to-voronoi ({ROTULO_MALHA})")
    save(fig, "06_cape_24h.png")
    return cape


def plot_07_olr(lat, lon):
    olr = load_field(DIAG_FINAL, "olrtoa")
    lon_g, lat_g, Z = regrid(lat, lon, olr)
    fig, ax = new_fig()
    mesh = ax.contourf(lon_g, lat_g, Z, levels=np.linspace(80, 320, 21), cmap="gray_r", transform=ccrs.PlateCarree(), extend="both")
    cbar = fig.colorbar(mesh, ax=ax, fraction=0.045, pad=0.04)
    cbar.set_label("OLR no topo da atmosfera (W/m²)")
    ax.set_title(f"Radiação de onda longa no topo (OLR), válido {VALID_LABEL} (+24h)\nrota nativa voronoi-to-voronoi ({ROTULO_MALHA})")
    save(fig, "07_olr_24h.png")


def plot_08_evolucao():
    precip_mean = []
    cape_mean = []
    cin_mean = []
    rc0 = load_field(f"{FCST_DIR}/diag.{TIMES[0]}.00.00.nc", "rainc")
    rn0 = load_field(f"{FCST_DIR}/diag.{TIMES[0]}.00.00.nc", "rainnc")
    for t in TIMES:
        path = f"{FCST_DIR}/diag.{t}.00.00.nc"
        rc = load_field(path, "rainc"); rn = load_field(path, "rainnc")
        acc = (rc - rc0) + (rn - rn0)
        precip_mean.append(float(np.nanmean(acc)))
        cape_mean.append(float(np.nanmean(load_field(path, "cape"))))
        cin_mean.append(float(np.nanmean(load_field(path, "cin"))))

    fig, ax1 = plt.subplots(figsize=(10, 5.5))
    ax2 = ax1.twinx()
    l1, = ax1.plot(HOURS, precip_mean, "o-", color="blue", label="Precipitação acumulada média (mm)")
    l2, = ax2.plot(HOURS, cape_mean, "s-", color="red", label="CAPE médio (J/kg)")
    l3, = ax2.plot(HOURS, cin_mean, "^-", color="green", label="CIN médio (J/kg)")
    ax1.set_xlabel("Horas de previsão")
    ax1.set_ylabel("Precipitação acumulada média no domínio (mm)", color="blue")
    ax2.set_ylabel("CAPE / CIN médios no domínio (J/kg)", color="red")
    ax1.tick_params(axis="y", labelcolor="blue")
    ax2.tick_params(axis="y", labelcolor="red")
    ax1.legend(handles=[l1, l2, l3], loc="upper left")
    ax1.set_title(
        "Evolução temporal (0-24h): precipitação, CAPE e CIN médios no domínio\n"
        f"rota nativa voronoi-to-voronoi ({ROTULO_MALHA})"
    )
    save(fig, "08_evolucao_precip_cape_cin.png")


def main():
    print("--- carregando malha estatica ---")
    ds = load_static()
    lat, lon = latlon_deg(ds)
    ter = ds["ter"].values
    bdy = ds["bdyMaskCell"].values

    print("--- 00 dominio/terreno ---")
    plot_00_dominio_terreno(lat, lon, ter, bdy)

    print("--- 02 mslp+vento10m ---")
    plot_02_mslp(lat, lon)

    print("--- 03 t2m ---")
    plot_03_t2m(lat, lon)

    print("--- 04 geopotencial+vento500 ---")
    plot_04_z500(lat, lon)

    print("--- 05 precipitacao ---")
    plot_05_precip(lat, lon)

    print("--- 06 cape ---")
    cape_final = plot_06_cape(lat, lon)

    print("--- 01 malha zoom (usa CAPE ja carregado) ---")
    plot_01_malha_zoom(ds, cape_final)

    print("--- 07 olr ---")
    plot_07_olr(lat, lon)

    print("--- 08 evolucao temporal ---")
    plot_08_evolucao()

    print("=== CONCLUIDO ===")


if __name__ == "__main__":
    main()
