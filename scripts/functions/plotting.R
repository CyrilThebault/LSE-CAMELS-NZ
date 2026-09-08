# ==============================================================================
# Common plotting conventions
# ==============================================================================


# ==============================================================================
# Emulator colours
# ==============================================================================

emulator_colours <- c(
  RF     = "#0072B2",
  GBMv01 = "#D55E00",
  GBMv02 = "#009E73"
)


# ==============================================================================
# Experiment aesthetics
# ==============================================================================

experiment_linetypes <- c(
  daily  = "solid",
  hourly = "dashed"
)

experiment_shapes <- c(
  daily  = 16,
  hourly = 17
)


# ==============================================================================
# KGE plotting limits
# ==============================================================================

kge_limits <- c(-0.41, 1)

kge_reference_y <- function() {
  
  list(ggplot2::geom_hline(yintercept = 1, linetype = "dotted", linewidth = 0.5),
    ggplot2::coord_cartesian(ylim = kge_limits),
    ggplot2::scale_y_continuous( breaks = c(-0.4, -0.2, 0, 0.2, 0.4, 0.6, 0.8, 1)))
}


kge_reference_x <- function() {
  
  list( ggplot2::geom_vline(xintercept = 1, linetype = "dotted", linewidth = 0.5),
    ggplot2::coord_cartesian(xlim = kge_limits),
    ggplot2::scale_x_continuous(breaks = c(-0.4, -0.2, 0, 0.2, 0.4, 0.6, 0.8, 1)))
}



# ==============================================================================
# Common ggplot theme
# ==============================================================================

theme_lse <- function(base_size = 11) {

  ggplot2::theme_bw(base_size = base_size) +
    ggplot2::theme(panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major = ggplot2::element_line(linewidth = 0.25, colour = "grey85"),
      strip.background = ggplot2::element_rect(fill = "grey95", colour = "grey60"),
      strip.text = ggplot2::element_text(face = "bold"),
      legend.position = "right",
      legend.title = ggplot2::element_blank())
}





# ==============================================================================
# Fold colour intensity
# ==============================================================================

make_fold_colours <- function(base_colour, folds) {

  folds <- unique(as.character(folds))
  folds <- sort(folds)

  shades <- grDevices::colorRampPalette(
    c("grey85", base_colour)
  )(length(folds))

  stats::setNames(shades, folds)
}
