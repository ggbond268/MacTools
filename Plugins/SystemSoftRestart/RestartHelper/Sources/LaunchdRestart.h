#ifndef LaunchdRestart_h
#define LaunchdRestart_h

#include <stdint.h>
#include <sys/types.h>

typedef struct {
    int32_t attemptedCount;
    int32_t stoppedCount;
    int32_t failedCount;
} MTRestartSummary;

typedef void (*MTRestartDiagnosticCallback)(
    const char *label,
    int32_t errorNumber,
    void *context
);

int32_t MTRestartUserJobs(
    pid_t helperProcessIdentifier,
    pid_t hostProcessIdentifier,
    MTRestartSummary *summary,
    MTRestartDiagnosticCallback diagnosticCallback,
    void *diagnosticContext
);

#endif
