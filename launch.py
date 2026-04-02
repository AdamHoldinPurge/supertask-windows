#!/usr/bin/env python3
"""Launcher script for SuperTask™ Windows Edition."""
import sys
import os

# Ensure the project directory is on the path
project_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, project_dir)

from supertask.main import main
main()
