#include "LaunchdRestart.h"

#include <errno.h>
#include <launch.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <strings.h>

// FixTim's restart mechanism depends on the legacy per-user launchd dictionary API.
// Keep the deprecated calls isolated in this compatibility unit.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

typedef struct {
    pid_t helperProcessIdentifier;
    pid_t hostProcessIdentifier;
    MTRestartSummary summary;
    MTRestartDiagnosticCallback diagnosticCallback;
    void *diagnosticContext;
} MTRestartContext;

static void MTReportFailure(MTRestartContext *context, const char *label, int errorNumber) {
    if (context == NULL) {
        return;
    }
    context->summary.failedCount += 1;
    if (context->diagnosticCallback != NULL) {
        context->diagnosticCallback(
            label == NULL ? "Unknown launchd job" : label,
            errorNumber == 0 ? EIO : errorNumber,
            context->diagnosticContext
        );
    }
}

static bool MTStringContainsCaseInsensitive(const char *value, const char *searchValue) {
    if (value == NULL || searchValue == NULL) {
        return false;
    }

    size_t searchLength = strlen(searchValue);
    if (searchLength == 0) {
        return true;
    }

    for (const char *cursor = value; *cursor != '\0'; cursor++) {
        if (strncasecmp(cursor, searchValue, searchLength) == 0) {
            return true;
        }
    }
    return false;
}

static bool MTIsCriticalLoginJob(const char *label) {
    return MTStringContainsCaseInsensitive(label, "loginwindow")
        || MTStringContainsCaseInsensitive(label, "windowserver");
}

static void MTRestartJob(
    const launch_data_t value,
    const char *key,
    void *rawContext
) {
    (void)key;
    MTRestartContext *context = rawContext;
    if (context == NULL || value == NULL || launch_data_get_type(value) != LAUNCH_DATA_DICTIONARY) {
        return;
    }

    launch_data_t pidData = launch_data_dict_lookup(value, LAUNCH_JOBKEY_PID);
    launch_data_t labelData = launch_data_dict_lookup(value, LAUNCH_JOBKEY_LABEL);
    if (pidData == NULL || labelData == NULL
        || launch_data_get_type(pidData) != LAUNCH_DATA_INTEGER
        || launch_data_get_type(labelData) != LAUNCH_DATA_STRING) {
        return;
    }

    long long rawProcessIdentifier = launch_data_get_integer(pidData);
    if (rawProcessIdentifier <= 1 || rawProcessIdentifier > INT32_MAX) {
        return;
    }
    pid_t processIdentifier = (pid_t)rawProcessIdentifier;
    const char *label = launch_data_get_string(labelData);
    if (processIdentifier <= 1 || label == NULL
        || processIdentifier == context->helperProcessIdentifier
        || processIdentifier == context->hostProcessIdentifier
        || MTIsCriticalLoginJob(label)
        || kill(processIdentifier, 0) != 0) {
        return;
    }

    context->summary.attemptedCount += 1;
    launch_data_t stopRequest = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
    launch_data_t labelCopy = launch_data_new_string(label);
    if (stopRequest == NULL || labelCopy == NULL) {
        if (labelCopy != NULL) {
            launch_data_free(labelCopy);
        }
        if (stopRequest != NULL) {
            launch_data_free(stopRequest);
        }
        MTReportFailure(context, label, ENOMEM);
        return;
    }

    if (!launch_data_dict_insert(stopRequest, labelCopy, LAUNCH_KEY_STOPJOB)) {
        launch_data_free(labelCopy);
        launch_data_free(stopRequest);
        MTReportFailure(context, label, EINVAL);
        return;
    }

    launch_data_t stopResponse = launch_msg(stopRequest);
    if (stopResponse == NULL) {
        launch_data_free(stopRequest);
        MTReportFailure(context, label, errno);
        return;
    }

    if (launch_data_get_type(stopResponse) == LAUNCH_DATA_ERRNO) {
        int errorNumber = launch_data_get_errno(stopResponse);
        if (errorNumber == 0 || errorNumber == ESRCH) {
            context->summary.stoppedCount += 1;
        } else {
            MTReportFailure(context, label, errorNumber);
        }
    } else {
        context->summary.stoppedCount += 1;
    }

    launch_data_free(stopResponse);
    launch_data_free(stopRequest);
}

int32_t MTRestartUserJobs(
    pid_t helperProcessIdentifier,
    pid_t hostProcessIdentifier,
    MTRestartSummary *summary,
    MTRestartDiagnosticCallback diagnosticCallback,
    void *diagnosticContext
) {
    if (summary == NULL || helperProcessIdentifier <= 1 || hostProcessIdentifier <= 1) {
        return EINVAL;
    }

    *summary = (MTRestartSummary){0};
    launch_data_t request = launch_data_new_string(LAUNCH_KEY_GETJOBS);
    if (request == NULL) {
        return ENOMEM;
    }

    launch_data_t response = launch_msg(request);
    launch_data_free(request);
    if (response == NULL) {
        return EIO;
    }
    if (launch_data_get_type(response) != LAUNCH_DATA_DICTIONARY) {
        launch_data_free(response);
        return EIO;
    }

    MTRestartContext context = {
        .helperProcessIdentifier = helperProcessIdentifier,
        .hostProcessIdentifier = hostProcessIdentifier,
        .summary = {0},
        .diagnosticCallback = diagnosticCallback,
        .diagnosticContext = diagnosticContext,
    };
    launch_data_dict_iterate(response, MTRestartJob, &context);
    launch_data_free(response);
    *summary = context.summary;

    return context.summary.attemptedCount > 0 ? 0 : ESRCH;
}

#pragma clang diagnostic pop
