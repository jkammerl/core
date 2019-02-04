load("@io_bazel_rules_docker//container:container.bzl", "container_bundle")
load("@io_bazel_rules_docker//contrib:push-all.bzl", "container_push")
load("@cloud_robotics//bazel/build_rules:expand_vars.bzl", "expand_vars")
load("@cloud_robotics//bazel/build_rules:helm_chart.bzl", "helm_chart")
load("@cloud_robotics//bazel/build_rules:qualify_images.bzl", "qualify_images")
load("@cloud_robotics//bazel/build_rules/robco_app_chart:cache_gcr_credentials.bzl", "cache_gcr_credentials")
load("@cloud_robotics//bazel/build_rules/robco_app_chart:run_sequentially.bzl", "run_sequentially")

def app_chart(
        name,
        registry,
        docker_tag = "latest",
        values = None,
        extra_templates = None,
        extra_values = None,
        files = None,
        images = None,
        visibility = None):
    """Macro for a standard Cloud Robotics helm chart.

    This macro establishes two subrules for chart name "foo-cloud":
    - :foo-cloud.push pushes the Docker images for the chart (if relevant).
    - :foo-cloud.snippet-yaml is a snippet of YAML defining the chart, which is
      used by app() to generate an App CR containing multiple inline
      charts.

    Args:
      name: string. Must be in the format {app}-{chart}, where chart is
        robot, cloud, or cloud-per-robot.
      registry: string. The docker registry for image pushes (gcr.io/my-project).
      docker_tag: string. Defaults to latest.
      values: file. The values.yaml file.
      extra_templates: list of files. Extra files for the chart's templates/ directory.
      extra_values: string. This is a YAML string for the "values" field  of
        the app CR. This can be used to pass extra parameters to the app.
      files: list of files. Extra non-template files for the chart's files/ directory.
      images: dict. Images referenced by the chart.
      visibility: Visibility.
    """
    _, chart = name.rsplit("-", 1)
    if name.endswith("cloud-per-robot"):
        chart = "cloud-per-robot"

    if not values:
        if chart == "cloud":
            values = "@cloud_robotics//bazel/build_rules/robco_app_chart:values-cloud.yaml"
        else:
            values = "@cloud_robotics//bazel/build_rules/robco_app_chart:values-robot.yaml"

    expand_vars(
        name = name + "-chart-yaml",
        out = name + "-chart.yaml",
        substitutions = {"name": name, "version": "0.0.1"},
        template = "@cloud_robotics//bazel/build_rules/robco_app_chart:Chart.yaml.template",
    )

    source_digests = []
    cmds = [
        "cat $(location {}) - > $@ <<EOF".format(values),
        "### Generated by app_chart ###",
        "images:",
    ]
    images = images or {}
    for key, value in images.items():
        image_label = Label(value)
        digest = "//{}:{}.digest".format(image_label.package, image_label.name)
        cmds.append("  {nick}: {registry}/{image}@$$(cat $(location {digest}))".format(
            nick = key.replace("-", "_"),
            registry = registry,
            image = key,
            digest = digest,
        ))
        source_digests.append(digest)
    cmds.append("EOF")

    native.genrule(
        name = name + ".values-yaml",
        srcs = [values] + source_digests,
        outs = [name + "-values.yaml"],
        cmd = "\n".join(cmds),
    )

    helm_chart(
        name = name,
        chart = ":" + name + "-chart-yaml",
        templates = native.glob([chart + "/*.yaml"]) + (extra_templates or []),
        files = files,
        values = ":" + name + ".values-yaml",
        # TODO(b/72936439): This is currently unused and fixed to 0.0.1.
        version = "0.0.1",
        visibility = visibility,
    )

    container_bundle(
        name = name + ".container-bundle",
        images = qualify_images(images, registry, docker_tag),
    )
    container_push(
        name = name + ".push-all-containers",
        bundle = name + ".container-bundle",
        format = "Docker",
    )

    run_sequentially(
        name = name + ".push-cached-credentials",
        # The conditional works around container_push's inability to handle
        # an empty dict of containers:
        # https://github.com/bazelbuild/rules_docker/issues/511
        targets = [name + ".push-all-containers"] if images else [],
    )

    cache_gcr_credentials(
        name = name + ".push",
        target = name + ".push-cached-credentials",
        gcr_registry = registry,
        visibility = visibility,
    )

    extra_values_yaml = ""
    if extra_values:
        extra_values_yaml = "\n".join(["values: |-"] + ["      " + s for s in extra_values.split("\n")])

    native.genrule(
        name = name + ".snippet-yaml",
        srcs = [name],
        outs = [name + ".snippet.yaml"],
        cmd = """cat <<EOF > $@
  - installation_target: {target}
    name: {name}
    version: 0.0.1
    inline_chart: $$(base64 -w 0 $<)
    {extra_values_yaml}
EOF
""".format(
            name = name,
            target = chart.upper().replace("-", "_"),
            values_header = "values: |-\n" if extra_values else "",
            extra_values_yaml = extra_values_yaml,
        ),
    )