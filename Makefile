# Run project
run:
	uv run python manage.py makemigrations
	uv run python manage.py migrate
	uv run python manage.py collectstatic --no-input --clear >> /dev/null
	uv run python manage.py runserver
# Initialize initial data
init:
	uv run python manage.py inituser
	uv run python manage.py initcore
# Run migrations only
migrate:
	uv run python manage.py makemigrations
	uv run python manage.py migrate
# Run tests
test:
	uv run python manage.py test
# Clean cache
clean:
	find . -type d -name "__pycache__" -exec rm -r {} +
	find . -type f -name "*.pyc" -delete
# Create superuser
superuser:
	uv run python manage.py createsuperuser
# Code formatting and linting with auto-fix
check:
	uv run --group dev black .
	uv run --group dev ruff check . --fix
# Install dependencies with uv
install:
	uv sync
	uv sync --group dev
# Activate virtual environment
shell:
	uv shell
