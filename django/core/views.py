from django.conf import settings
from django.shortcuts import render


def home(request):
	return render(request, "core/index.html", {"server_id": settings.SERVER_ID})
