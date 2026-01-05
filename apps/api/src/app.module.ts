import { Module } from '@nestjs/common';
// import { DatabaseModule } from './database/database.module'; // Vamos comentar se não criou ainda
// import { CoursesModule } from './courses/courses.module'; // Vamos comentar se não criou ainda

@Module({
  imports: [
    // DatabaseModule,
    // CoursesModule
  ],
  controllers: [],
  providers: [],
})
export class AppModule {}
