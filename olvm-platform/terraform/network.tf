resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_block     = var.vcn_cidr_block
  display_name   = "${local.name_base}-vcn"
  dns_label      = substr(replace(local.name_base, "-", ""), 0, 15)

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.name_base}-igw"
  enabled        = true

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.name_base}-public-rt"

  route_rules {
    description       = "Default route to the internet gateway"
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.name_base}-public-sl"

  # External access from ssh_allowed_cidr: individual TCP ports (SSH 22, OLVM web
  # portals 80/443).
  dynamic "ingress_security_rules" {
    for_each = toset(var.allowed_ingress_ports)
    content {
      description = "Allow TCP port ${ingress_security_rules.value} from the configured CIDR range"
      protocol    = "6"
      source      = var.ssh_allowed_cidr
      source_type = "CIDR_BLOCK"

      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  # External access from ssh_allowed_cidr: TCP port ranges (OLVM console
  # VNC/SPICE proxy range 5900-6923).
  dynamic "ingress_security_rules" {
    for_each = var.allowed_ingress_port_ranges
    content {
      description = "Allow TCP ports ${ingress_security_rules.value.min}-${ingress_security_rules.value.max} from the configured CIDR range"
      protocol    = "6"
      source      = var.ssh_allowed_cidr
      source_type = "CIDR_BLOCK"

      tcp_options {
        min = ingress_security_rules.value.min
        max = ingress_security_rules.value.max
      }
    }
  }

  # Internal machine-to-machine traffic: allow ALL protocols/ports between hosts
  # inside the VCN. This is what enables the Engine, KVM hosts, and NFS server to
  # communicate over every port they need (vdsm 54321/54322, libvirt 16509/16514,
  # live migration 49152-49216, console 5900-6923, NFS 2049/111/20048, SSH, etc.)
  # without enumerating each one at the cloud layer.
  dynamic "ingress_security_rules" {
    for_each = var.allow_all_intra_vcn ? [1] : []
    content {
      description = "Allow all traffic between machines inside the VCN"
      protocol    = "all"
      source      = var.vcn_cidr_block
      source_type = "CIDR_BLOCK"
    }
  }

  egress_security_rules {
    description      = "Allow outbound traffic"
    protocol         = "all"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
  }

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.public_subnet_cidr_block
  display_name               = "${local.name_base}-public-subnet"
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}
