from apps.lecture.models import FavoriteLecture, CurrentLecture, LectureProgress


class TopicPlayerManager:
    """Manager class for topic player logic"""

    def __init__(self, user, topic):
        self.user = user
        self.topic = topic
        self.lectures = topic.lectures.all()

    @property
    def is_authenticated(self):
        return self.user.is_authenticated

    def get_current_lecture_data(self):
        """Get current lecture and its progress"""
        if not self.is_authenticated:
            return None, None

        current_lecture_obj = CurrentLecture.objects.filter(
            user=self.user, topic=self.topic
        ).first()

        if not current_lecture_obj:
            return None, None

        current_lecture = current_lecture_obj.lecture
        current_lecture_progress = LectureProgress.objects.filter(
            user=self.user, lecture=current_lecture
        ).first()

        return current_lecture, current_lecture_progress

    def _create_default_progress(self):
        """Create default progress object"""
        return type(
            "Progress",
            (object,),
            {
                "progress_percentage": 0,
                "completed": False,
                "listen_count": 0,
                "current_time": 0,
            },
        )()

    def _get_user_progress_data(self):
        """Get user's progress and favorites data"""
        if not self.is_authenticated:
            return {}, set()

        progress_records = LectureProgress.objects.filter(
            user=self.user, lecture__in=self.lectures
        ).select_related("lecture")

        progress_dict = {record.lecture.id: record for record in progress_records}

        favorite_lectures = set(
            FavoriteLecture.objects.filter(
                user=self.user, lecture__in=self.lectures
            ).values_list("lecture_id", flat=True)
        )

        return progress_dict, favorite_lectures

    def attach_lecture_data(self):
        """Attach progress and favorite data to lectures"""
        progress_dict, favorite_lectures = self._get_user_progress_data()

        for lecture in self.lectures:
            lecture.progress = progress_dict.get(
                lecture.id, self._create_default_progress()
            )
            lecture.is_favorite = lecture.id in favorite_lectures

    def get_context_data(self):
        """Get all context data for template"""
        current_lecture, current_lecture_progress = self.get_current_lecture_data()
        self.attach_lecture_data()

        return {
            "topic": self.topic,
            "lectures": self.lectures,
            "lecture_count": self.lectures.count(),
            "current_lecture": current_lecture,
            "current_lecture_progress": current_lecture_progress,
        }
