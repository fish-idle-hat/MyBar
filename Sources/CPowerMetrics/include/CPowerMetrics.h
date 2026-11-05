#ifndef C_POWER_METRICS_H
#define C_POWER_METRICS_H

typedef struct ThermoBarPowerSampler ThermoBarPowerSampler;

typedef struct {
    double cpu_watts;
    double gpu_watts;
    int has_cpu;
    int has_gpu;
} ThermoBarPowerReading;

ThermoBarPowerSampler *thermobar_power_sampler_create(void);
void thermobar_power_sampler_destroy(ThermoBarPowerSampler *sampler);
int thermobar_power_sampler_read(
    ThermoBarPowerSampler *sampler,
    ThermoBarPowerReading *reading
);

#endif
