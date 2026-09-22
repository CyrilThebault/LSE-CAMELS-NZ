#!/usr/bin/env Rscript

# ==============================================================================
# Compare performance across LSE experiments
#
# Each experiment root must contain a results_summary.csv produced by
# 01_collect_results.R.
#
# Examples:
#
# Hourly k-fold versus hourly allseen:
#
# Rscript scripts/05_analysis/03_compare_experiment_performance.R \
#   "$PWD" \
#   "$PWD/experiments/hourly/kfold" \
#   "$PWD/experiments/hourly/allseen"
#
# Daily versus hourly k-fold:
#
# Rscript scripts/05_analysis/03_compare_experiment_performance.R \
#   "$PWD" \
#   "$PWD/experiments/daily/kfold" \
#   "$PWD/experiments/hourly/kfold"
# ==============================================================================


# ==============================================================================
# Arguments
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 3L) {
  stop(
    paste0(
      "Usage: Rscript 03_compare_experiment_performance.R ",
      "<dirMain> <experiment_root_1> <experiment_root_2> [...]"
    )
  )
}

dirMain <- normalizePath(args[1], mustWork = TRUE)

experiment_roots <- vapply(
  args[-1],
  normalizePath,
  character(1),
  mustWork = TRUE
)


# ==============================================================================
# Functions and plotting configuration
# ==============================================================================

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/plotting.R"))

suppressPackageStartupMessages(library(ggplot2))


# ==============================================================================
# Read experiments
# ==============================================================================

all_results <- vector("list", length(experiment_roots))

for (i in seq_along(experiment_roots)) {

  exp_root <- experiment_roots[i]
  file_results <- file.path(exp_root, "results_summary.csv")

  if (!file.exists(file_results)) {
    stop("Missing results summary: ", file_results)
  }

  x <- read.csv(file_results, stringsAsFactors = FALSE)

  required_columns <- c(
    "fold", "step", "ID", "emulator", "eNKGE",
    "KGEc", "NKGEc", "KGEe", "rank"
  )

  missing_columns <- setdiff(required_columns, names(x))

  if (length(missing_columns)) {
    stop(
      "Missing required column(s) in ", file_results, ": ",
      paste(missing_columns, collapse = ", ")
    )
  }

  if (!nrow(x)) {
    stop("results_summary.csv contains no results: ", file_results)
  }

  # Expected directory structure:
  # experiments/<timestep>/<experiment>/

  experiment_name <- basename(exp_root)
  timestep <- basename(dirname(exp_root))

  x$timestep <- timestep
  x$experiment <- experiment_name
  x$scenario <- paste(timestep, experiment_name, sep = " / ")

  # Compare each experiment at its own final available refinement step.

  finite_steps <- x$step[is.finite(x$step) & is.finite(x$KGEe)]

  if (!length(finite_steps)) {
    stop("No finite KGEe values available in ", file_results)
  }

  final_step <- max(finite_steps)

  x <- x[
    x$step == final_step & is.finite(x$KGEe),
    ,
    drop = FALSE
  ]

  if (!nrow(x)) {
    stop("No finite final-step KGEe values available in ", file_results)
  }

  x$final_step <- final_step
  all_results[[i]] <- x
}

results <- do.call(rbind, all_results)


# ==============================================================================
# Factors
# ==============================================================================

preferred_emulator_order <- c("RF", "GBMv01", "GBMv02")

emulator_order <- preferred_emulator_order[
  preferred_emulator_order %in% unique(results$emulator)
]

unexpected_emulators <- setdiff(unique(results$emulator), emulator_order)

if (length(unexpected_emulators)) {
  emulator_order <- c(emulator_order, sort(unexpected_emulators))
}

scenario_order <- unique(results$scenario)

results$emulator <- factor(results$emulator, levels = emulator_order)
results$scenario <- factor(results$scenario, levels = scenario_order)


# ==============================================================================
# Output directory
# ==============================================================================

comparison_name <- paste(
  gsub(" / ", "_", scenario_order, fixed = TRUE),
  collapse = "__vs__"
)

plot_dir <- ensure_dir(
  file.path(dirMain, "plots", "comparisons", comparison_name)
)

save_figure <- function(plot, filename, width = 8, height = 5.5) {

  ggsave(
    file.path(plot_dir, paste0(filename, ".pdf")),
    plot,
    width = width,
    height = height,
    device = grDevices::pdf
  )

  if (capabilities("png")) {
    ggsave(
      file.path(plot_dir, paste0(filename, ".png")),
      plot,
      width = width,
      height = height,
      dpi = 300,
      device = grDevices::png
    )
  } else {
    message("PNG device unavailable; skipping ", filename, ".png")
  }
}


# ==============================================================================
# ECDF
# ==============================================================================

ecdf_rows <- list()
j <- 0L

for (scenario in scenario_order) {
  for (ml in emulator_order) {

    values <- results$KGEe[
      as.character(results$scenario) == scenario &
        as.character(results$emulator) == ml
    ]

    values <- sort(values[is.finite(values)])

    if (!length(values)) {
      next
    }

    j <- j + 1L

    ecdf_rows[[j]] <- data.frame(
      scenario = scenario,
      emulator = ml,
      KGEe = values,
      probability = seq_along(values) / length(values),
      stringsAsFactors = FALSE
    )
  }
}

ecdf_data <- do.call(rbind, ecdf_rows)

ecdf_data$emulator <- factor(ecdf_data$emulator, levels = emulator_order)
ecdf_data$scenario <- factor(ecdf_data$scenario, levels = scenario_order)

p1 <- ggplot(
  ecdf_data,
  aes(
    x = KGEe,
    y = probability,
    colour = emulator,
    linetype = scenario,
    group = interaction(emulator, scenario)
  )
) +
  geom_step(linewidth = 0.85) +
  scale_colour_manual(values = emulator_colours) +
  kge_reference_x() +
  labs(
    x = "Evaluation KGE",
    y = "Empirical cumulative probability",
    colour = "Emulator",
    linetype = "Experiment"
  ) +
  theme_lse()

save_figure(p1, "01_kgee_ecdf_comparison")


# ==============================================================================
# Paired basin-wise KGE comparison
# ==============================================================================

if (length(scenario_order) == 2L) {

  scenario_x <- scenario_order[1]
  scenario_y <- scenario_order[2]

  x_data <- results[
    as.character(results$scenario) == scenario_x,
    c("ID", "emulator", "KGEe"),
    drop = FALSE
  ]

  y_data <- results[
    as.character(results$scenario) == scenario_y,
    c("ID", "emulator", "KGEe"),
    drop = FALSE
  ]

  names(x_data)[names(x_data) == "KGEe"] <- "KGEe_x"
  names(y_data)[names(y_data) == "KGEe"] <- "KGEe_y"

  paired_data <- merge(
    x_data,
    y_data,
    by = c("ID", "emulator"),
    all = FALSE
  )

  paired_data <- paired_data[
    is.finite(paired_data$KGEe_x) &
      is.finite(paired_data$KGEe_y),
    ,
    drop = FALSE
  ]

  if (nrow(paired_data)) {

    paired_data$emulator <- factor(
      paired_data$emulator,
      levels = emulator_order
    )

    paired_data$delta_KGEe <- paired_data$KGEe_y - paired_data$KGEe_x


    # ==========================================================================
    # 1:1 comparison
    # ==========================================================================

    p2 <- ggplot(
      paired_data,
      aes(
        x = KGEe_x,
        y = KGEe_y,
        colour = emulator
      )
    ) +
      geom_abline(
        slope = 1,
        intercept = 0,
        linetype = "dashed",
        linewidth = 0.6
      ) +
      geom_point(
        size = 1.5,
        alpha = 0.55
      ) +
      scale_colour_manual(values = emulator_colours) +
      kge_reference_x() +
      kge_reference_y() +
      coord_equal(
        xlim = c(-0.41, 1),
        ylim = c(-0.41, 1),
        expand = FALSE
      ) +
      facet_wrap(~ emulator, nrow = 1) +
      labs(
        x = paste0("Evaluation KGE — ", scenario_x),
        y = paste0("Evaluation KGE — ", scenario_y)
      ) +
      theme_lse() +
      theme(legend.position = "none")

    save_figure(
      p2,
      "02_kgee_paired_comparison",
      width = 12,
      height = 4.5
    )


    # ==========================================================================
    # Spatial distribution of paired KGE differences
    # ==========================================================================

    spatial <- load_nz_spatial_data(dirMain)

    map_data <- join_station_results(
      spatial$stations,
      paired_data
    )

    if (!nrow(map_data)) {
      stop("No station IDs matched the paired comparison results.")
    }

    map_data$emulator <- factor(
      map_data$emulator,
      levels = emulator_order
    )

    delta_label <- paste0("ΔKGEe\n(", scenario_y, " - ", scenario_x, ")")

    p3 <- ggplot() +
      geom_sf(
        data = spatial$nz,
        fill = "grey95",
        colour = "grey55",
        linewidth = 0.25
      ) +
      geom_sf(
        data = map_data,
        aes(fill = delta_KGEe),
        shape = 21,
        colour = "black",
        stroke = 0.25,
        size = 2.0,
        alpha = 0.9
      ) +
      scale_fill_gradient2(
        low = "#B2182B",
        mid = "#F7F7F7",
        high = "#2166AC",
        midpoint = 0,
        limits = c(-0.5, 0.5),
        oob = scales::squish,
        breaks = c(-0.5, -0.25, 0, 0.25, 0.5),
        labels = c("< -0.5", "-0.25", "0", "0.25", "> 0.5"),
        name = delta_label
      ) +
      facet_wrap(~ emulator, nrow = 1) +
      coord_sf(datum = NA) +
      labs(x = NULL, y = NULL) +
      theme_lse() +
      theme(
        axis.text = element_blank(),
        axis.ticks = element_blank(),
        panel.grid = element_blank(),
        legend.position = "right",
        legend.title = element_text()
      )

    save_figure(
      p3,
      "03_delta_kgee_map",
      width = 11,
      height = 5.5
    )


    # --------------------------------------------------------------------------
    # Paired comparison summary
    # --------------------------------------------------------------------------

    paired_summary <- do.call(
      rbind,
      lapply(emulator_order, function(ml) {

        d <- paired_data[
          as.character(paired_data$emulator) == ml,
          ,
          drop = FALSE
        ]

        if (!nrow(d)) {
          return(NULL)
        }

        delta <- d$delta_KGEe

        data.frame(
          scenario_x = scenario_x,
          scenario_y = scenario_y,
          emulator = ml,
          n_basins = nrow(d),
          mean_delta_KGEe = mean(delta),
          median_delta_KGEe = median(delta),
          pct_y_gt_x = mean(delta > 0) * 100,
          pct_y_eq_x = mean(delta == 0) * 100,
          pct_y_lt_x = mean(delta < 0) * 100,
          stringsAsFactors = FALSE
        )
      })
    )

    write.csv(
      paired_summary,
      file.path(plot_dir, "paired_comparison_summary.csv"),
      row.names = FALSE
    )

  } else {
    message("No common basin/emulator pairs; skipping paired comparison.")
  }

} else {
  message(
    "Paired comparison requires exactly two scenarios; ",
    "skipping paired comparison and delta map."
  )
}


# ==============================================================================
# Performance summary
# ==============================================================================

summary_rows <- list()
j <- 0L

for (scenario in scenario_order) {

  scenario_data <- results[
    as.character(results$scenario) == scenario,
    ,
    drop = FALSE
  ]

  for (ml in emulator_order) {

    x <- scenario_data$KGEe[
      as.character(scenario_data$emulator) == ml
    ]

    x <- x[is.finite(x)]

    if (!length(x)) {
      next
    }

    j <- j + 1L

    summary_rows[[j]] <- data.frame(
      timestep = unique(scenario_data$timestep),
      experiment = unique(scenario_data$experiment),
      scenario = scenario,
      final_step = unique(scenario_data$final_step),
      emulator = ml,
      n_basins = length(x),
      mean_KGEe = mean(x),
      median_KGEe = median(x),
      sd_KGEe = sd(x),
      q05_KGEe = unname(quantile(x, 0.05)),
      q25_KGEe = unname(quantile(x, 0.25)),
      q75_KGEe = unname(quantile(x, 0.75)),
      q95_KGEe = unname(quantile(x, 0.95)),
      pct_KGEe_gt_0 = mean(x > 0) * 100,
      pct_KGEe_gt_0_5 = mean(x > 0.5) * 100,
      stringsAsFactors = FALSE
    )
  }
}

performance_summary <- do.call(rbind, summary_rows)

write.csv(
  performance_summary,
  file.path(plot_dir, "performance_comparison.csv"),
  row.names = FALSE
)


# ==============================================================================
# Final report
# ==============================================================================

cat("\nCompared experiments:\n")

for (scenario in scenario_order) {
  cat("  - ", scenario, "\n", sep = "")
}

cat("\nSaved comparison outputs to:\n")
cat("  ", plot_dir, "\n", sep = "")

print(performance_summary)