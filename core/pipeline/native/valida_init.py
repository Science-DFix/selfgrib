import netCDF4 as nc
import numpy as np

real = nc.Dataset('/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/SouthAmerica/init_run/SouthAmerica.init.nc')
ours = nc.Dataset('/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/SouthAmerica/init_run_native/SouthAmerica.init.nc')

def cmp(name):
    r = np.array(real.variables[name][:], dtype=np.float64).squeeze()
    o = np.array(ours.variables[name][:], dtype=np.float64).squeeze()
    d = np.abs(o - r)
    print(f'{name:16s} real[min,max]=({r.min():.5g},{r.max():.5g}) erro_abs[mean,max]=({d.mean():.4g},{d.max():.4g})')

for nm in ['rho', 'theta', 'qv', 'u', 'w', 'surface_pressure', 'precipw', 'skintemp', 'tmn', 'vegfra']:
    cmp(nm)

print()
print('nosso vars:', len(ours.variables), ' real vars:', len(real.variables))
faltando = set(real.variables.keys()) - set(ours.variables.keys())
print('faltando no nosso:', sorted(faltando))
